module db.conversation;

import core.time: TimeException;
import db.config: getConfig;
import db.email;
import db.mongo;
import db.tagcontainer;
import db.user;
import std.algorithm;
import std.path;
import std.regex;
import std.stdio;
import std.string;
import std.typecons;
import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;

/**
 * From removes variants of "Re:"/"RE:"/"re:" in the subject
 */
auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");

private string clearSubject(in string subject)
{
    return replaceAll!(x => "")(subject, SUBJECT_CLEAN_REGEX);
}


struct MessageLink
{
    string messageId;
    string emailDbId;
    bool deleted;
}


final class Conversation
{
    string dbId;
    string userDbId;
    string lastDate;

    MessageLink[] links;
    string[] attachFileNames;
    string cleanSubject;
    private TagContainer m_tags;

    bool     hasTag(in string tag) const { return m_tags.has(tag);  }
    bool     hasTags(in string[] tags) const { return m_tags.has(tags); }
    void     addTag(in string tag)           { m_tags.add(tag);         }
    void     removeTag(in string tag)        { m_tags.remove(tag);      }
    string[] tagsArray()            const { return m_tags.array;     }
    uint     numTags()              const { return m_tags.length;    }


    bool hasLink(in string messageId, in string emailDbId)
    {
        foreach(ref link; this.links)
            if (link.messageId == messageId && link.emailDbId == emailDbId)
                return true;
        return false;
    }


    /** Adds a new link (email in the thread) to the conversation */
    // FIXME: update this.lastDate
    void addLink(in string messageId, in string emailDbId="", in bool deleted=false)
    {
        assert(messageId.length);
        if (!messageId.length)
            throw new Exception("Conversation.addLink: First MessageId parameter " ~
                                "must have length");
        if (!hasLink(messageId, emailDbId))
            this.links ~= MessageLink(messageId, emailDbId, deleted);
    }


    /** Return only the links that are in the DB */
    // FIXME: the result is changed on the Api, see workarounds (changeLink()
    // or something like that)
    MessageLink*[] receivedLinks()
    {
        MessageLink*[] res;
        foreach(ref link; this.links)
        {
            if (link.emailDbId.length)
                res ~= &link;
        }
        return res;
    }


    // FIXME: naive copy of the entire links list, I probably should use some container
    // with fast removal or this could have problems with threads with hundreds of messages
    // FIXME: update this.lastDate
    void removeLink(in string emailDbId)
    {
        assert(emailDbId.length);
        enforce(emailDbId.length);

        MessageLink[] newLinks;
        bool someReceivedRemaining = false;
        string lastDate = "";

        foreach(link; this.links)
        {
            if (link.emailDbId != emailDbId)
            {
                newLinks ~= link;
                if (!someReceivedRemaining && link.emailDbId.length)
                    someReceivedRemaining = true;
            }
        }

        this.links = newLinks;
        if (!someReceivedRemaining) // no local emails => remove conversation
        {
            this.remove();
            this.dbId = "";
        }
    }


    /** Update the lastDate field if the argument is newer*/
    private void updateLastDate(in string newIsoDate)
    nothrow
    {
        if (!this.lastDate.length || this.lastDate < newIsoDate)
            this.lastDate = newIsoDate;
    }


    private string toJson()
    {
        auto linksApp = appender!string;
        foreach(const ref link; this.links)
            linksApp.put(format(`{"message-id": "%s",` ~
                                `"emailId": "%s",` ~
                                `"deleted": %s},`,
                                link.messageId,
                                link.emailDbId,
                                link.deleted));
        return format(`
        {
            "_id": %s,
            "userId": %s,
            "lastDate": %s,
            "cleanSubject": %s,
            "tags": %s,
            "links": [%s]
        }`, Json(this.dbId).toString, Json(this.userDbId).toString,
            Json(this.lastDate).toString, Json(this.cleanSubject).toString,
            this.m_tags.array, linksApp.data);
    }

    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================

    // FIXME: error control
    void store()
    {
        collection("conversation").update(
                ["_id": this.dbId],
                parseJsonString(this.toJson),
                UpdateFlags.Upsert
        );
    }


    /** Note: this will NOT remove the contained emails from the DB */
    void remove()
    {
        if (!this.dbId.length)
        {
            logWarn("Conversation.remove: empty DB id, is this conversation stored?");
            return;
        }
        collection("conversation").remove(["_id": this.dbId]);
    }


    /** Returns null if no Conversation with those references was found. */
    static Conversation get(in string id)
    {
        immutable convDoc = collection("conversation").findOne(["_id": id]);
        return convDoc.isNull ? null : Conversation.docToObject(convDoc);
    }


    /**
     * Return the first Conversation that has ANY of the references contained in its
     * links. Returns null if no Conversation with those references was found.
     */
    static Conversation getByReferences(in string userId,
                                        in string[] references,
                                        in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        string[] reversed = references.dup;
        reverse(reversed);
        Appender!string jsonApp;
        jsonApp.put(format(`{"userId":"%s","links.message-id":{"$in":%s},`,
                           userId, reversed));
        if (!withDeleted)
            jsonApp.put(`"tags": {"$nin": ["deleted"]},`);
        jsonApp.put("}");

        immutable convDoc = collection("conversation").findOne(
                parseJsonString(jsonApp.data)
        );
        return docToObject(convDoc);
    }


    static Conversation getByEmailId(in string emailId,
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


    static Conversation[] getByTag(in string tagName,
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
                    ret ~= Conversation.docToObject(doc);
        }
        return ret;
    }


    version(unittest) // support functions for testing
    {
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
    }

    /**
     * Insert or update a conversation with this email messageId, references, tags
     * and date
     */
    static Conversation upsert(in Email email,
                               in string[] tagsToAdd,
                               in string[] tagsToRemove)
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
        conv.m_tags.add(tagsToAdd);
        conv.m_tags.remove(tagsToRemove);

        // add our references; addLink() only adds the new ones
        foreach(reference; references)
            conv.addLink(reference, Email.messageIdToDbId(reference), email.deleted);

        bool wasInConversation = false;
        if (conv.dbId.length)
        {
            // existing conversation: see if this email msgid is on the conversation links,
            // (can happen if an email referring to this one entered the system before this
            // email); if so update the conversation with the EmailId
            foreach(ref entry; conv.links)
            {
                if (entry.messageId == messageId)
                {
                    entry.emailDbId   = email.dbId;
                    entry.deleted     = email.deleted;
                    wasInConversation = true;
                    break;
                }
            }
        }
        else
            conv.dbId = BsonObjectID.generate().toString;

        if (!wasInConversation)
            conv.addLink(messageId, email.dbId, email.deleted);

        // update the conversation cleaned subject (last one wins)
        if (email.hasHeader("subject"))
            conv.cleanSubject = clearSubject(email.getHeader("subject").rawValue);

        conv.store();

        Email.setConversationInEmailIndex(email.dbId, conv.dbId);
        return conv;
    }


    static private Conversation docToObject(const ref Bson convDoc)
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
            ret.addLink(bsonStr(link["message-id"]), emailId, bsonBool(link["deleted"]));

            // FIXME: instead of reading ALL the email docs to get the attachments, store
            // a list of attach filenames inside the Conversation document=>link
            if (emailId.length)
            {
                const emailSummary = Email.getSummary(emailId);
                foreach(const ref attach; emailSummary.attachFileNames)
                {
                    if (countUntil(ret.attachFileNames, attach) == -1)
                        ret.attachFileNames ~= attach;
                }
            }
        }
        return ret;
    }


    // Find any conversation with this email and update the links.[email].deleted field
    static string setEmailDeleted(in string dbId, in bool setDel)
    {
        auto conv = Conversation.getByEmailId(dbId);
        if (conv is null)
        {
            logWarn(format("setEmailDeleted: No conversation found for email with id (%s)", dbId));
            return "";
        }

        foreach(ref entry; conv.links)
        {
            if (entry.emailDbId == dbId)
            {
                if (entry.deleted == setDel)
                    logWarn(format("setEmailDeleted: delete state for email (%s) in "
                                   "conversation was already %s", dbId, setDel));
                else
                {
                    entry.deleted = setDel;
                    conv.store();
                }
                break;
            }
        }
        return conv.dbId;
    }


    static bool isOwnedBy(string convId, string userName)
    {
        immutable userId = User.getIdFromLoginName(userName);
        if (!userId.length)
            return false;

        auto convDoc = collection("conversation").findOne(["_id": convId, "userId": userId],
                                                   ["_id": 1],
                                                   QueryFlags.None);
        return !convDoc.isNull;
    }
}




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
    import db.user;

    unittest // Conversation.get/docToObject
    {
        writeln("Testing Conversation.get/docToObject");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        assert(convs.length == 1);
        auto conv  = Conversation.get(convs[0].dbId);
        assert(conv !is null);
        assert(conv.lastDate.length); // this email date is set to NOW
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 2);
        assert(conv.attachFileNames == ["google.png", "profilephoto.jpeg"]);
        assert(conv.cleanSubject == ` some subject "and quotes" and noquotes`);
        assert(conv.links[0].deleted == false);

        convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        conv = Conversation.get(convs[1].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-06-10T12:51:10Z");
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 3);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
        assert(conv.links[0].deleted == false);

        conv = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 1);
        assert(conv.attachFileNames.length == 1);
        assert(conv.attachFileNames[0] == "C++ Pocket Reference.pdf");
        assert(conv.cleanSubject == " Attachment test");
        assert(conv.links[0].deleted == false);
    }

    unittest // Conversation.remove
    {
        writeln("Testing Conversation.remove");
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

    unittest // Conversation.hasLink
    {
        writeln("Testing Conversation.hasLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        const emailDbId = conv.links[0].emailDbId;
        const emailMsgId = conv.links[0].messageId;
        assert(conv.hasLink(emailMsgId, emailDbId));
        assert(!conv.hasLink("blabla", emailDbId));
        assert(!conv.hasLink(emailMsgId, "blabla"));
        assert(!conv.hasLink(emailDbId, emailMsgId));
    }

    unittest // Conversation.addLink
    {
        writeln("Testing Conversation.addLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[0];
        assert(conv.links.length == 1);
        // check it doesnt add the same link twice
        const emailDbId = conv.links[0].emailDbId;
        const emailMsgId = conv.links[0].messageId;
        const deleted = conv.links[0].deleted;
        conv.addLink(emailMsgId, emailDbId, deleted);
        assert(conv.links.length == 1);

        // check that it adds a new link
        conv.addLink("someMessageId", "someEmailDbId", false);
        assert(conv.links.length == 2);
        assert(conv.links[1].messageId == "someMessageId");
        assert(conv.links[1].emailDbId == "someEmailDbId");
        assert(!conv.links[1].deleted);
    }

    unittest // Conversation.removeLink
    {
        writeln("Testing Conversation.removeLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[1];
        assert(conv.links.length == 3);
        const link0 = conv.links[0];
        const link1 = conv.links[1];
        const emailId = conv.links[2].emailDbId;
        conv.removeLink(emailId);
        assert(conv.links.length == 2);
        assert(conv.links[0].messageId == link0.messageId);
        assert(conv.links[0].emailDbId == link0.emailDbId);
        assert(conv.links[1].messageId == link1.messageId);
        assert(conv.links[1].emailDbId == link1.emailDbId);
    }


    unittest // Conversation.receivedLinks
    {
        writeln("Testing Conversation.receivedLinks");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[0];
        assert(conv.links.length == 1);
        assert(conv.receivedLinks.length == 1);

        conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[1];
        assert(conv.links.length == 3);
        assert(conv.receivedLinks.length == 1);

        conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[2];
        assert(conv.links.length == 1);
        assert(conv.receivedLinks.length == 1);

        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(conv.links.length == 2);
        assert(conv.receivedLinks.length == 2);
        auto convId = conv.dbId;
        foreach(ref link; conv.receivedLinks)
            link.deleted = true;
        conv.store();
        conv = Conversation.get(convId);
        assert(conv.links[0].deleted);
        assert(conv.links[1].deleted);
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

    unittest // Conversation.remove
    {
        writeln("Testing Conversation.remove");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        auto copyConvs = convs.dup;
        convs[0].remove();
        auto newconvs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(newconvs.length == 2);
        assert(newconvs[0].dbId == copyConvs[1].dbId);
        assert(newconvs[1].dbId == copyConvs[2].dbId);
    }

    unittest // Conversation.store
    {
        writeln("Testing Conversation.store");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        // update existing (id doesnt change)
        convs[0].addTag("newtag");
        convs[0].addLink("someMessageId");
        auto oldDbId = convs[0].dbId;
        convs[0].store();

        auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs2.length == 3);
        assert(convs2[0].dbId == oldDbId);
        assert(convs2[0].hasTag("inbox"));
        assert(convs2[0].hasTag("newtag"));
        assert(convs2[0].numTags == 2);
        assert(convs2[0].links[1].messageId == "someMessageId");

        // create new (new dbId)
        convs2[0].dbId = BsonObjectID.generate().toString;
        convs2[0].store();
        auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs3.length == 4);

        bool found = false;
        foreach(conv; convs3)
        {
            if (conv.dbId == convs2[0].dbId)
            {
                found = true;
                assert(conv.userDbId == convs2[0].userDbId);
                assert(conv.lastDate == convs2[0].lastDate);
                assert(conv.numTags == convs2[0].numTags);
                assert(convs2[0].hasTags(conv.tagsArray));
                assert(conv.attachFileNames == convs2[0].attachFileNames);
                assert(conv.cleanSubject == convs2[0].cleanSubject);
                foreach(idx, link; conv.links)
                {
                    assert(link.messageId == convs2[0].links[idx].messageId);
                    assert(link.emailDbId == convs2[0].links[idx].emailDbId);
                    assert(link.deleted == convs2[0].links[idx].deleted);
                }
            }
        }
        assert(found);

    }

    unittest // Conversation.getByTag
    {
        writeln("Testing Conversation.getByTag");
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
        Conversation.addTagDb(convs4[0].dbId, "deleted");
        convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
        assert(convs4.length == len1-1);
        // except when using Yes.WithDeleted
        convs4 = Conversation.getByTag(
                "inbox", USER_TO_ID["anotherUser"], 1000, 0, Yes.WithDeleted
        );
        assert(convs4.length == len1);
    }

    unittest // Conversation.addTagDb / removeTagDb
    {
        writeln("Testing Conversation.addTagDb");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        assert(convs.length);
        auto dbId = convs[0].dbId;
        Conversation.addTagDb(dbId, "testTag");
        auto conv = Conversation.get(dbId);
        assert(conv !is null);
        assert(conv.hasTag("testtag"));

        writeln("Testing Conversation.removeTagDb");
        Conversation.removeTagDb(dbId, "testTag");
        conv = Conversation.get(dbId);
        assert(!conv.hasTag("testtag"));
    }

    unittest // upsert
    {
        import db.email;
        import db.user;
        import retriever.incomingemail;

        void assertConversationInEmailIndex(string emailId, string convId)
        {
            auto emailIdxDoc =
                collection("emailIndexContents").findOne(["emailDbId": emailId]);
            assert(!emailIdxDoc.isNull);
            assert(bsonStr(emailIdxDoc.convId) == convId);
        }

        writeln("Testing Conversation.upsert");
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                               "testemails");
        auto inEmail = new IncomingEmailImpl();
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
        auto convId  = Conversation.upsert(dbEmail, tagsToAdd, []).dbId;
        auto convDoc = collection("conversation").findOne(["_id": convId]);

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
        assert(!convObject.attachFileNames.length);
        assert(convObject.links[0].deleted == false);


        // test2: insert as a msgid of a reference already on a conversation, check that the right
        // conversationId is returned and the emailId added to its entry in the conversation.links
        recreateTestDb();
        inEmail = new IncomingEmailImpl();
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
        convId = Conversation.upsert(dbEmail, tagsToAdd, []).dbId;
        convDoc = collection("conversation").findOne(["_id": convId]);
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
        assert(!convObject.attachFileNames.length);
        assert(convObject.links[0].deleted == false);

        // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
        // is added to that conversation
        recreateTestDb();
        inEmail = new IncomingEmailImpl();
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
        inEmail.addHeader(refHeader);
        dbEmail = new Email(inEmail);
        dbEmail.setOwner(dbEmail.localReceivers()[0]);
        assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
        emailId = dbEmail.store();
        convId  = Conversation.upsert(dbEmail, tagsToAdd, []).dbId;
        convDoc = collection("conversation").findOne(["_id": convId]);

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
        assert(convObject.attachFileNames.length == 1);
        assert(convObject.attachFileNames[0] == "C++ Pocket Reference.pdf");
        assert(convObject.links[1].deleted == false);
    }

    unittest // Conversation.getByReferences
    {
        writeln("Testing Conversation.getByReferences");
        recreateTestDb();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        assert(user1 !is null);
        assert(user2 !is null);
        assert(user1.id.length);
        assert(user2.id.length);

        auto conv = Conversation.getByReferences(user1.id,
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


        conv = Conversation.getByReferences(user2.id, ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tagsArray == ["inbox"]);
        assert(conv.links.length == 1);
        assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[0].deleted == false);

        Conversation.addTagDb(conv.dbId, "deleted");
        // check that it doesnt returns the deleted convs
        conv = Conversation.getByReferences(user2.id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv is null);
        // except when using Yes.WithDeleted
        conv = Conversation.getByReferences(user2.id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"],
                Yes.WithDeleted);
        assert(conv !is null);
    }


    unittest // getByEmailId
    {
        writeln("Testing Conversation.getByEmailId");
        recreateTestDb();

        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto conv = Conversation.getByReferences(user1.id,
                ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);

        auto conv2 = Conversation.getByEmailId(conv.links[0].emailDbId);
        assert(conv2 !is null);
        assert(conv.dbId == conv2.dbId);

        auto conv3 = Conversation.getByEmailId("doesntexist");
        assert(conv3 is null);
    }

    unittest // clearSubject
    {
        writeln("Testing Conversation.clearSubject");
        assert(clearSubject("RE: polompos") == "polompos");
        assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
        assert(clearSubject("Pok and something Re: things") == "Pok and something things");
    }

    unittest // isOwnedBy
    {
        writeln("Testing Conversation.isOwnedBy");
        recreateTestDb();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        assert(user1 !is null);
        assert(user2 !is null);
        assert(user1.id.length);
        assert(user2.id.length);

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
