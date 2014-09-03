module db.mongo.driverconversationmongo;


version(MongoDriver)
{
import common.utils;
import db.config: getConfig;
import db.conversation: Conversation;
import db.dbinterface.driverconversationinterface;
import db.mongo.mongo;
import db.user: User;
import std.algorithm;
import std.path;
import std.regex;
import std.string;
import std.typecons;
import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;


private string clearSubject(in string subject)
{
    return replaceAll!(x => "")(subject, SUBJECT_CLEAN_REGEX);
}


final class DriverConversationMongo : DriverConversationInterface
{
    private static Conversation docToObject(const ref Bson convDoc)
    {
        if (convDoc.isNull)
            return null;

        assert(!convDoc.links.isNull);

        auto ret         = new Conversation();
        ret.dbId         = bsonStr(convDoc._id);
        ret.userDbId     = bsonStr(convDoc.userId);
        ret.lastDate     = bsonStr(convDoc.lastDate);
        ret.cleanSubject = bsonStr(convDoc.cleanSubject);

        foreach(tag; bsonStrArray(convDoc.tags))
            ret.addTag(tag);

        foreach(link; convDoc.links)
        {
            immutable emailId = bsonStr(link["emailId"]);
            const attachNames = bsonStrArraySafe(link["attachNames"]);
            ret.addLink(bsonStr(link["message-id"]), attachNames, emailId, bsonBool(link["deleted"]));
        }
        return ret;
    }


    private static void addTagDb(in string dbId, in string tag)
    {
        assert(dbId.length);
        assert(tag.length);

        auto json = format(`{"$push":{"tags":"%s"}}`, tag);
        auto bson = parseJsonString(json);
        collection("conversation").update(["_id": dbId], bson);
    }

    private static void removeTagDb(in string dbId, in string tag)
    {
        assert(dbId.length);
        assert(tag.length);

        auto json = format(`{"$pull":{"tags":"%s"}}`, tag);
        auto bson = parseJsonString(json);
        collection("conversation").update(["_id": dbId], bson);
    }

override: // XXX reactivar
    /** Returns null if no Conversation with those references was found. */
    Conversation get(in string id)
    {
        immutable convDoc = findOneById("conversation", id);
        return convDoc.isNull ? null : docToObject(convDoc);
    }


    /**
     * Return the first Conversation that has ANY of the references contained in its
     * links. Returns null if no Conversation with those references was found.
     */
    Conversation getByReferences(in string userId,
                                 in string[] references,
                                 in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        string[] reversed = references.dup;
        reverse(reversed);
        Appender!string jsonApp;
        jsonApp.put(format(`{"userId":"%s","links.message-id":{"$in":%s},`,
                           userId, reversed));
        if (!withDeleted)
        {
            jsonApp.put(`"tags": {"$nin": ["deleted"]},`);
        }
        jsonApp.put("}");

        immutable convDoc = collection("conversation").findOne(parseJsonString(jsonApp.data));
        return docToObject(convDoc);
    }


    Conversation getByEmailId(in string emailId,
                              in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        Appender!string jsonApp;
        jsonApp.put(format(`{"links.emailId": {"$in": %s},`, [emailId]));
        if (!withDeleted)
            jsonApp.put(`"tags": {"$nin": ["deleted"]},`);
        jsonApp.put("}");

        immutable convDoc = collection("conversation").findOne(parseJsonString(jsonApp.data));
        return docToObject(convDoc);
    }


    Conversation[] getByTag(in string tagName,
                            in string userId,
                            in uint limit=0,
                            in uint page=0,
                            in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        Appender!string jsonApp;
        jsonApp.put(format(`{"tags": {"$in": [%s]},`, Json(tagName).toString));
        if (!withDeleted)
            jsonApp.put(`"tags":{"$nin":["deleted"]},`);
        jsonApp.put(format(`"userId": %s}`, Json(userId).toString));

        auto cursor = collection("conversation").find(
                parseJsonString(jsonApp.data),
                Bson(null),
                QueryFlags.None,
                page*limit // skip
        ).sort(["lastDate": -1]);
        cursor.limit(limit);

        Conversation[] ret;
        foreach(ref doc; cursor)
        {
            if (!doc.isNull)
                    ret ~= docToObject(doc);
        }
        return ret;
    }


    void store(Conversation conv)
    {
        collection("conversation").update(
                ["_id": conv.dbId],
                parseJsonString(conv.toJson),
                UpdateFlags.Upsert
        );
    }


    // Note: this will NOT remove the contained emails from the DB
    void remove(in string id)
    {
        if (!id.length)
        {
            logWarn("DriverConversationMongo.remove: empty DB id, is this conversation stored?");
            return;
        }
        collection("conversation").remove(["_id": id]);
    }


    /**
     * Insert or update a conversation with this email messageId, references, tags
     * and date
     */
    import db.email;
    Conversation addEmail(in Email email, in string[] tagsToAdd, in string[] tagsToRemove)
    {
        assert(email.userId.length);
        assert(email.dbId.length);

        const references     = email.getHeader("references").addresses;
        immutable messageId  = email.messageId;

        auto conv = Conversation.getByReferences(email.userId, references ~ messageId);
        if (conv is null)
            conv = new Conversation();
        conv.userDbId = email.userId;

        // date: will only be set if newer than lastDate
        conv.updateLastDate(email.isoDate);

        // tags
        map!(x => conv.addTag(x))(tagsToAdd);
        map!(x => conv.removeTag(x))(tagsToRemove);

        // add the email's references: addLink() only adds the new ones
        string[] empty;
        foreach(reference; references)
        {
            conv.addLink(reference, empty, Email.messageIdToDbId(reference), email.deleted);
        }

        bool wasInConversation = false;
        if (conv.dbId.length)
        {
            // existing conversation: see if this email msgid is on the conversation links,
            // (can happen if an email referring to this one entered the system before this
            // email); if so update the link with the full data we've now
            foreach(ref entry; conv.links)
            {
                if (entry.messageId == messageId)
                {
                    entry.emailDbId   = email.dbId;
                    entry.deleted     = email.deleted;
                    wasInConversation = true;
                    foreach(ref attach; email.attachments.list)
                    {
                        entry.attachNames ~= attach.filename;
                    }
                    break;
                }
            }
        }
        else
            conv.dbId = BsonObjectID.generate().toString;

        if (!wasInConversation)
        {
            // get the attachFileNames and add this email to the conversation
            const emailSummary = Email.getSummary(email.dbId);
            conv.addLink(messageId, emailSummary.attachFileNames, email.dbId, email.deleted);
        }

        // update the conversation cleaned subject (last one wins)
        if (email.hasHeader("subject"))
            conv.cleanSubject = clearSubject(email.getHeader("subject").rawValue);

        conv.store();

        // update the emailIndexContent reverse link to the Conversation
        // (for madz speed)
        const indexBson = parseJsonString(
                format(`{"$set": {"convId": "%s"}}`, conv.dbId)
        );
        collection("emailIndexContents").update(["emailDbId": email.dbId], indexBson);
        return conv;
    }


    // Find any conversation with this email and update the links.[email].deleted field
    string setEmailDeleted(in string emailDbId, in bool setDel)
    {
        auto conv = getByEmailId(emailDbId);
        if (conv is null)
        {
            logWarn(format("setEmailDeleted: No conversation found for email with id (%s)", 
                           emailDbId));
            return "";
        }

        foreach(ref entry; conv.links)
        {
            if (entry.emailDbId == emailDbId)
            {
                if (entry.deleted == setDel)
                    logWarn(format("setEmailDeleted: delete state for email (%s) in "
                                   "conversation was already %s", emailDbId, setDel));
                else
                {
                    entry.deleted = setDel;
                    store(conv);
                }
                break;
            }
        }
        return conv.dbId;
    }


    bool isOwnedBy(in string convId, in string userName)
    {
        import db.user;
        immutable userId = User.getIdFromLoginName(userName);
        if (!userId.length)
            return false;

        immutable convDoc = collection("conversation").findOne(["_id": convId, "userId": userId],
                                                   ["_id": 1],
                                                   QueryFlags.None);
        return !convDoc.isNull;
    }
}
} // end version(MongoDriver)


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


version(db_test)
version(db_usetestdb)
{

    import db.test_support;
    import std.stdio;

    unittest // get/docToObject
    {
        writeln("Testing DriverConversationMongo.get/docToObject");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        assert(convs.length == 1);
        auto conv  = Conversation.get(convs[0].dbId);
        assert(conv !is null);
        assert(conv.lastDate.length); // this email date is set to NOW
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 2);
        assert(conv.links[1].attachNames == ["google.png", "profilephoto.jpeg"]);
        assert(conv.cleanSubject == ` some subject "and quotes" and noquotes`);
        assert(conv.links[0].deleted == false);

        convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        conv = Conversation.get(convs[1].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-06-10T12:51:10Z");
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 3);
        assert(!conv.links[0].attachNames.length);
        assert(!conv.links[1].attachNames.length);
        assert(!conv.links[2].attachNames.length);
        assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
        assert(conv.links[0].deleted == false);

        conv = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 1);
        assert(conv.links[0].attachNames.length == 1);
        assert(conv.links[0].attachNames[0] == "C++ Pocket Reference.pdf");
        assert(conv.cleanSubject == " Attachment test");
        assert(conv.links[0].deleted == false);
    }


    unittest // getByTag
    {
        writeln("Testing DriverConversationMongo.getByTag");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        assert(convs[0].lastDate > convs[2].lastDate);
        assert(convs[0].links[0].deleted == false);

        auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 0);
        assert(convs2.length == 2);
        assert(convs2[0].dbId == convs[0].dbId);
        assert(convs2[1].dbId == convs[1].dbId);
        assert(convs2[0].links[0].deleted == false);
        assert(convs2[1].links[0].deleted == false);

        auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 1);
        assert(convs3.length == 1);
        assert(convs3[0].dbId == convs[2].dbId);

        auto convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
        assert(convs4[0].dbId == convs[0].dbId);
        assert(convs4[1].dbId == convs[1].dbId);
        assert(convs4[2].dbId == convs[2].dbId);
        assert(convs4[0].links[0].deleted == false);
        assert(convs4[1].links[0].deleted == false);
        assert(convs4[2].links[0].deleted == false);

        // check that it doesnt returns the deleted convs
        auto len1 = convs4.length;
        DriverConversationMongo.addTagDb(convs4[0].dbId, "deleted");
        convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
        assert(convs4.length == len1-1);
        // except when using Yes.WithDeleted
        convs4 = Conversation.getByTag(
                "inbox", USER_TO_ID["anotherUser"], 1000, 0, Yes.WithDeleted
        );
        assert(convs4.length == len1);
    }


    unittest // getByReferences
    {
        writeln("Testing DriverConversationMongo.getByReferences");
        recreateTestDb();
        auto user1id = USER_TO_ID["testuser"];
        auto user2id = USER_TO_ID["anotherUser"];

        auto conv = Conversation.getByReferences(user1id,
                ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2013-05-27T05:42:30Z");
        assert(conv.tagsArray == ["inbox"]);
        assert(conv.links.length == 2);
        assert(conv.links[1].messageId ==
                "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[1].emailDbId.length);
        assert(conv.links[0].deleted == false);
        assert(conv.links[1].deleted == false);


        conv = Conversation.getByReferences(user2id, ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tagsArray == ["inbox"]);
        assert(conv.links.length == 1);
        assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[0].deleted == false);

        DriverConversationMongo.addTagDb(conv.dbId, "deleted");
        // check that it doesnt returns the deleted convs
        conv = Conversation.getByReferences(user2id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv is null);
        // except when using Yes.WithDeleted
        conv = Conversation.getByReferences(user2id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"],
                Yes.WithDeleted);
        assert(conv !is null);
    }


    unittest // getByEmailId
    {
        writeln("Testing DriverConversationMongo.getByEmailId");
        recreateTestDb();

        auto conv = Conversation.getByReferences(USER_TO_ID["testuser"],
                ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);

        auto conv2 = Conversation.getByEmailId(conv.links[0].emailDbId);
        assert(conv2 !is null);
        assert(conv.dbId == conv2.dbId);

        auto conv3 = Conversation.getByEmailId("doesntexist");
        assert(conv3 is null);
    }


    unittest // addTagDb / removeTagDb
    {
        writeln("Testing DriversConversationMongo.addTagDb");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        assert(convs.length);
        auto dbId = convs[0].dbId;
        DriverConversationMongo.addTagDb(dbId, "testTag");
        auto conv = Conversation.get(dbId);
        assert(conv !is null);
        assert(conv.hasTag("testtag"));

        writeln("Testing DriverConversationMongo.removeTagDb");
        DriverConversationMongo.removeTagDb(dbId, "testTag");
        conv = Conversation.get(dbId);
        assert(!conv.hasTag("testtag"));
    }

    unittest // remove
    {
        writeln("Testing DriverConversationMongo.remove");
        recreateTestDb();
        auto convs = Conversation.getByTag( "inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        const id = convs[0].dbId;
        convs[0].remove();
        convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 2);
        foreach(conv; convs)
            assert(conv.dbId != id);
    }

    unittest // addEmail
    {
        import retriever.incomingemail;

        void assertConversationInEmailIndex(string emailId, string convId)
        {
            auto emailIdxDoc =
                collection("emailIndexContents").findOne(["emailDbId": emailId]);
            assert(!emailIdxDoc.isNull);
            assert(bsonStr(emailIdxDoc.convId) == convId);
        }

        writeln("Testing DriverConversationMongo.addEmail");
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                               "testemails");
        auto inEmail = new IncomingEmail();
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                                     getConfig().attachmentStore);

        auto user = User.getFromAddress(inEmail.getHeader("to").addresses[0]);
        assert(user !is null);
        string[] tagsToAdd = ["inbox", "anothertag"];

        // test1: insert as is, should create a new conversation with this email as single
        // member
        auto dbEmail = new Email(inEmail);
        dbEmail.setOwner(dbEmail.localReceivers()[0]);
        assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
        auto emailId = dbEmail.store();
        auto convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).dbId;
        auto convDoc = findOneById("conversation", convId);

        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId)                 == user.id);
        assert(convDoc.links.type                      == Bson.Type.array);
        assert(convDoc.links.length                    == 1);
        assert(bsonStr(convDoc.links[0]["message-id"]) == dbEmail.messageId);
        assert(bsonStr(convDoc.links[0].emailId)       == emailId);
        assert(convDoc.tags.type                       == Bson.Type.Array);
        assert(convDoc.tags.length                     == 2);
        assert(bsonStrArray(convDoc.tags)[0]           == "anothertag");
        assert(bsonStrArray(convDoc.tags)[1]           == "inbox");
        assert(bsonStr(convDoc.lastDate)               == dbEmail.isoDate);
        assertConversationInEmailIndex(emailId, convId);

        auto convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId     == convId);
        assert(convObject.userDbId == user.id);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        assert(convObject.hasTags(tagsToAdd));
        assert(convObject.links[0].messageId == inEmail.getHeader("message-id").addresses[0]);
        assert(convObject.links[0].emailDbId == emailId);
        assert(!convObject.links[0].attachNames.length);
        assert(convObject.links[0].deleted == false);


        // test2: insert as a msgid of a reference already on a conversation, check that the right
        // conversationId is returned and the emailId added to its entry in the conversation.links
        recreateTestDb();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        dbEmail = new Email(inEmail);
        auto testMsgId = "testreference@blabla.testdomain.com";
        inEmail.removeHeader("message-id");
        inEmail.addHeader("Message-ID: " ~ testMsgId);
        dbEmail.messageId = testMsgId;
        dbEmail.setOwner(dbEmail.localReceivers()[0]);
        assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
        emailId = dbEmail.store();
        convId = Conversation.addEmail(dbEmail, tagsToAdd, []).dbId;
        convDoc = findOneById("conversation", convId);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == user.id);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 3);
        assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);
        assertConversationInEmailIndex(emailId, convId);

        convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == user.id);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        assert(convObject.hasTags(tagsToAdd));
        assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].messageId == dbEmail.messageId);
        assert(convObject.links[1].emailDbId == emailId);
        assert(!convObject.links[1].attachNames.length);
        assert(convObject.links[0].deleted == false);

        // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
        // is added to that conversation
        recreateTestDb();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
        inEmail.addHeader(refHeader);
        dbEmail = new Email(inEmail);
        dbEmail.setOwner(dbEmail.localReceivers()[0]);
        assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
        emailId = dbEmail.store();
        convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).dbId;
        convDoc = findOneById("conversation", convId);

        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == user.id);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 2);
        assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);
        assertConversationInEmailIndex(emailId, convId);

        convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == user.id);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        assert(convObject.hasTags(tagsToAdd));
        assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].messageId == dbEmail.messageId);
        assert(convObject.links[1].emailDbId == emailId);
        assert(!convObject.links[1].attachNames.length);
        assert(convObject.links[1].deleted == false);
        assert(convObject.links[0].attachNames.length);
        assert(convObject.links[0].attachNames[0] == "C++ Pocket Reference.pdf");
    }

    unittest // clearSubject
    {
        writeln("Testing Conversation.clearSubject");
        assert(clearSubject("RE: polompos") == "polompos");
        assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
        assert(clearSubject("Pok and something Re: things") == "Pok and something things");
    }

    unittest // Conversation.setEmailDeleted
    {
        writeln("Testing Conversation.setEmailDeleted");
        recreateTestDb();

        auto conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        conv.setEmailDeleted(conv.links[0].emailDbId, true);
        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(conv.links[0].deleted);
        conv.setEmailDeleted(conv.links[0].emailDbId, false);
        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(!conv.links[0].deleted);
    }

    unittest // isOwnedBy
    {
        writeln("Testing Conversation.isOwnedBy");
        recreateTestDb();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");

        auto conv = Conversation.getByReferences(user1.id,
                ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(Conversation.isOwnedBy(conv.dbId, user1.loginName));

        conv = Conversation.getByReferences(user2.id,
            ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(Conversation.isOwnedBy(conv.dbId, user2.loginName));
    }
}
