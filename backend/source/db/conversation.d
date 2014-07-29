module db.conversation;

import std.string;
import std.path;
import std.algorithm;
import std.stdio;
import std.regex;
import core.time: TimeException;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import db.mongo;
import db.config: getConfig;
import db.email;

/**
 * From removes variants of "Re:"/"RE:"/"re:" in the subject
 */
auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");
private string clearSubject(string subject)
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
    string[] tags;
    MessageLink[] links;
    string[] attachFileNames;
    string cleanSubject;
    bool hasDeleted = false;

    private bool haveLink(string messageId, string emailDbId)
    {
        foreach(link; this.links)
            if (link.messageId == messageId && link.emailDbId == emailDbId)
                return true;
        return false;
    }
    void addLink(string messageId, string emailDbId, bool deleted)
    {
        if (!haveLink(messageId, emailDbId))
            this.links ~= MessageLink(messageId, emailDbId, deleted);
    }


    /** Update the lastDate field if the argument is newer */
    void updateLastDate(string newIsoDate)
    {
        if (!this.lastDate.length || this.lastDate < newIsoDate)
            this.lastDate = newIsoDate;
    }


    string toJson()
    {
        auto linksApp = appender!string;
        foreach(link; this.links)
            linksApp.put(format(`{"message-id": "%s",` ~
                                `"emailId": "%s",` ~
                                `"deleted": %s},`,
                                link.messageId, 
                                link.emailDbId,
                                link.deleted));
        return format(`
        {
            "_id": "%s",
            "userId": "%s",
            "lastDate": "%s",
            "cleanSubject": %s,
            "tags": %s,
            "links": [%s]
        }`, this.dbId, this.userDbId, 
            this.lastDate, Json(this.cleanSubject).toString,
            to!string(this.tags), linksApp.data);
    }

    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================

    /** Returns null if no Conversation with those references was found. */
    static Conversation get(string id)
    {
        auto convDoc = collection("conversation").findOne(["_id": id]);
        if (convDoc.isNull)
            return null;
        return Conversation.conversationDocToObject(convDoc);
    }

    /**
     * Return the first Conversation that has ANY of the references contained in its
     * links. Returns null if no Conversation with those references was found.
     */
    static Conversation getByReferences(string userId, const string[] references)
    {
        string[] reversed = references.dup;
        reverse(reversed);
        auto bson = parseJsonString(format(`{"userId": "%s",`~
                                           `"links.message-id": {"$in": %s}}`, 
                                           userId, reversed));
        auto convDoc = collection("conversation").findOne(bson);
        if (convDoc.isNull)
            return null;
        return conversationDocToObject(convDoc);
    }

    static Conversation[] getByTag(string tagName, uint limit, uint page)
    {
        Conversation[] ret;

        auto jsonFind = parseJsonString(format(`{"tags": {"$in": ["%s"]}}`, tagName));
        auto cursor   = collection("conversation").find(
                                                        jsonFind,
                                                        Bson(null),
                                                        QueryFlags.None,
                                                        page > 0? page*limit: 0 // skip
        ).sort(["lastDate": -1]);

        cursor.limit(limit);
        foreach(ref doc; cursor)
        {
            if (!doc.isNull)
                ret ~= Conversation.conversationDocToObject(doc);
        }
        return ret;
    }

    /**
     * Insert or update a conversation with this email messageId, references, tags
     * and date
     */
    static Conversation upsert(Email email, const bool[string] tags)
    {
        assert(email.userId.length);
        assert(email.dbId.length);
        const references = email.getHeader("references").addresses;
        const messageId  = email.messageId;

        auto conv = Conversation.getByReferences(email.userId, references ~ messageId);
        if (conv is null)
            conv = new Conversation();
        conv.userDbId = email.userId;

        // date: will only be set if newer than lastDate
        conv.updateLastDate(email.isoDate);

        // tags
        foreach(tagName, tagValue; tags)
            if (tagValue && countUntil(conv.tags, tagName) == -1)
                conv.tags ~= tagName;

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
                    entry.emailDbId = email.dbId;
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

        auto bson     = parseJsonString(conv.toJson);
        auto convColl = collection("conversation");
        convColl.update(["_id": conv.dbId], bson, UpdateFlags.Upsert);
        return conv;
    }

    static private Conversation conversationDocToObject(ref Bson convDoc)
    {
        auto ret = new Conversation();
        if (convDoc.isNull)
            return ret;

        ret.dbId         = bsonStr(convDoc._id);
        ret.userDbId     = bsonStr(convDoc.userId);
        ret.lastDate     = bsonStr(convDoc.lastDate);
        ret.tags         = bsonStrArray(convDoc.tags);
        ret.cleanSubject = bsonStr(convDoc.cleanSubject);

        assert(!convDoc.links.isNull);
        foreach(link; convDoc.links)
        {
            auto msgId = bsonStr(link["message-id"]);
            ret.addLink(msgId, bsonStr(link["emailId"]), bsonBool(link["deleted"]));
            auto emailSummary = Email.getSummary(Email.messageIdToDbId(msgId));
            foreach(attach; emailSummary.attachFileNames)
            {
                if (countUntil(ret.attachFileNames, attach) == -1)
                    ret.attachFileNames ~= attach;
            }
        }
        return ret;
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

    unittest // Conversation.get/conversationDocToObject
    {
        writeln("Testing Conversation.get/conversationDocToObject");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", 0, 0);
        auto conv  = Conversation.get(convs[0].dbId);
        assert(conv !is null);
        assert(conv.lastDate.length); // this email date is set to NOW
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 1);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Tired of Your Hosting Company?");
        assert(conv.links[0].deleted == false);

        conv = Conversation.get(convs[1].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-06-10T12:51:10Z");
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 3);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
        assert(conv.links[0].deleted == false);

        conv = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 1);
        assert(conv.attachFileNames.length == 1);
        assert(conv.attachFileNames[0] == "C++ Pocket Reference.pdf");
        assert(conv.cleanSubject == " Attachment test");
        assert(conv.links[0].deleted == false);
    }

    unittest // Conversation.getByTag
    {
        writeln("Testing Conversation.getByTag");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length == 4);
        assert(convs[0].lastDate > convs[3].lastDate);
        assert(convs[0].links[0].deleted == false);

        auto convs2 = Conversation.getByTag("inbox", 2, 0);
        assert(convs2.length == 2);
        assert(convs2[0].dbId == convs[0].dbId);
        assert(convs2[1].dbId == convs[1].dbId);
        assert(convs2[0].links[0].deleted == false);
        assert(convs2[1].links[0].deleted == false);

        auto convs3 = Conversation.getByTag("inbox", 2, 1);
        assert(convs3.length == 2);
        assert(convs3[0].dbId == convs[2].dbId);
        assert(convs3[1].dbId == convs[3].dbId);

        auto convs4 = Conversation.getByTag("inbox", 1000, 0);
        assert(convs4[0].dbId == convs[0].dbId);
        assert(convs4[1].dbId == convs[1].dbId);
        assert(convs4[2].dbId == convs[2].dbId);
        assert(convs4[3].dbId == convs[3].dbId);
        assert(convs4[0].links[0].deleted == false);
        assert(convs4[1].links[0].deleted == false);
        assert(convs4[2].links[0].deleted == false);
        assert(convs4[3].links[0].deleted == false);

    }

    unittest // upsert
    {
        import db.email;
        import db.user;
        import retriever.incomingemail;

        writeln("Testing Conversation.upsert");
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                               "testemails");
        auto inEmail = new IncomingEmailImpl();
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                                     getConfig().attachmentStore);

        auto user = User.getFromAddress(inEmail.getHeader("to").addresses[0]);
        assert(user !is null);
        bool[string] tags = ["inbox": true, "dontstore": false, "anothertag": true];
        // test1: insert as is, should create a new conversation with this email as single member
        auto dbEmail = new Email(inEmail);
        dbEmail.setOwner(dbEmail.localReceivers()[0]);
        assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
        auto emailId = dbEmail.store();
        auto convId  = Conversation.upsert(dbEmail, tags).dbId;
        auto convDoc = collection("conversation").findOne(["_id": convId]);

        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId)                 == user.id);
        assert(convDoc.links.type                      == Bson.Type.array);
        assert(convDoc.links.length                    == 1);
        assert(bsonStr(convDoc.links[0]["message-id"]) == dbEmail.messageId);
        assert(bsonStr(convDoc.links[0].emailId)       == emailId);
        assert(convDoc.tags.type                       == Bson.Type.Array);
        assert(convDoc.tags.length                     == 2);
        assert(bsonStrArray(convDoc.tags)[0]           == "inbox");
        assert(bsonStrArray(convDoc.tags)[1]           == "anothertag");
        assert(bsonStr(convDoc.lastDate)               == dbEmail.isoDate);

        auto convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == user.id);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
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
        inEmail.headers["message-id"].addresses[0] = testMsgId;
        dbEmail.messageId = testMsgId;
        dbEmail.setOwner(dbEmail.localReceivers()[0]);
        assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
        emailId = dbEmail.store();
        convId = Conversation.upsert(dbEmail, tags).dbId;
        convDoc = collection("conversation").findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == user.id);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 3);
        assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);

        convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == user.id);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
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
        convId  = Conversation.upsert(dbEmail, tags).dbId;
        convDoc = collection("conversation").findOne(["_id": convId]);

        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == user.id);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 2);
        assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);

        convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == user.id);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].messageId == dbEmail.messageId);
        assert(convObject.links[1].emailDbId == emailId);
        assert(convObject.attachFileNames.length == 1);
        assert(convObject.attachFileNames[0] == "C++ Pocket Reference.pdf");
        assert(convObject.links[1].deleted == false);
    }

    unittest // Conversation.getByReferences
    {
        import db.user;

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
        assert(conv.tags.length == 1);
        assert(conv.tags[0] == "inbox");
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
        assert(conv.tags.length == 1);
        assert(conv.tags[0] == "inbox");
        assert(conv.links.length == 1);
        assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[0].deleted == false);
    }

    unittest // clearSubject
    {
        writeln("Testing conversation.clearSubject");
        assert(clearSubject("RE: polompos") == "polompos");
        assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
        assert(clearSubject("Pok and something Re: things") == "Pok and something things");
    }
}
