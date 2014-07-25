module db.conversation;

//import std.datetime;
import std.string;
import std.path;
import std.algorithm;
import std.stdio;
import core.time: TimeException;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import db.mongo;
import retriever.incomingemail;

struct MessageLink
{
    string messageId;
    string emailDbId;
}


class Conversation
{
    string dbId;
    string userDbId;
    string lastDate;
    string[] tags;
    MessageLink[] links;
    string[] attachFileNames;
    string cleanSubject;

    private bool haveLink(string messageId, string emailDbId)
    {
        foreach(link; this.links)
            if (link.messageId == messageId && link.emailDbId == emailDbId)
                return true;
        return false;
    }

    void addLink(string messageId, string emailDbId)
    {
        if (!haveLink(messageId, emailDbId))
            this.links ~= MessageLink(messageId, emailDbId);
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
            linksApp.put(format(`{"message-id": "%s", "emailId": "%s"},`, 
                                link.messageId, link.emailDbId));
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

    // DB methods, puts these under a version() if other DBs are supported

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
        auto json = parseJsonString(format(`{"userId": "%s",`~
                                           `"links.message-id": {"$in": %s}}`, 
                                           userId, reversed));
        auto convDoc = collection("conversation").findOne(json);
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
    static Conversation upsert(const IncomingEmail email, string emailDbId,
            string userId, const bool[string] tags)
    {
        const references = email.getHeader("references").addresses;
        const messageId  = email.getHeader("message-id").addresses[0];

        auto conv = Conversation.getByReferences(userId, references ~ messageId);
        if (conv is null)
            conv = new Conversation();
        conv.userDbId = userId;

        // date: will only be set if newer than lastDate
        conv.updateLastDate(BsonDate(SysTime(email.date,
                        TimeZone.getTimeZone("GMT"))).toString);

        // tags
        foreach(tagName, tagValue; tags)
            if (tagValue && countUntil(conv.tags, tagName) == -1)
                conv.tags ~= tagName;

        // add our references; addLink() only adds the new ones
        foreach(reference; references)
            conv.addLink(reference, getEmailIdByMessageId(reference));

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
                    entry.emailDbId = emailDbId;
                    wasInConversation = true;
                    break;
                }
            }
        }
        else
            conv.dbId = BsonObjectID.generate().toString;

        if (!wasInConversation)
            conv.addLink(messageId, emailDbId);

        // update the conversation cleaned subject (last one wins)
        if (email.hasHeader("subject"))
            conv.cleanSubject = db.mongo.cleanSubject(email.getHeader("subject").rawValue);

        auto json     = parseJsonString(conv.toJson);
        auto convColl = collection("conversation");
        convColl.update(["_id": conv.dbId], json, UpdateFlags.Upsert);
        return conv;
    }

    static private Conversation conversationDocToObject(ref Bson convDoc)
    {
        auto ret = new Conversation();
        if (!convDoc.isNull)
        {
            ret.dbId         = bsonStr(convDoc._id);
            ret.userDbId     = bsonStr(convDoc.userId);
            ret.lastDate     = bsonStr(convDoc.lastDate);
            ret.tags         = bsonStrArray(convDoc.tags);
            ret.cleanSubject = bsonStr(convDoc.cleanSubject);

            foreach(link; convDoc.links)
            {
                auto msgId = bsonStr(link["message-id"]);
                ret.addLink(msgId, bsonStr(link["emailId"]));
                auto emailSummary = getEmailSummary(getEmailIdByMessageId(msgId));
                foreach(attach; emailSummary.attachFileNames)
                {
                    if (countUntil(ret.attachFileNames, attach) == -1)
                        ret.attachFileNames ~= attach;
                }
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
        writeln("Testing Conversation.get/getEmailSummary/conversationDocToObject");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", 0, 0);
        //writeln("XXX 1");
        auto conv  = Conversation.get(convs[0].dbId);
        //writeln("XXX 2");
        assert(conv !is null);
        //writeln("XXX 3");
        assert(conv.lastDate.length); // this email date is set to NOW
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 1);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Tired of Your Hosting Company?");
        //writeln("XXX 4");

        conv = Conversation.get(convs[1].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-06-10T12:51:10Z");
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 3);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
        //writeln("XXX 5");

        conv = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 1);
        assert(conv.attachFileNames.length == 1);
        assert(conv.attachFileNames[0] == "C++ Pocket Reference.pdf");
        assert(conv.cleanSubject == " Attachment test");
        //writeln("XXX 6");
    }

    unittest // Conversation.getByTag
    {
        writeln("Testing Conversation.getByTag");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length == 4);
        assert(convs[0].lastDate > convs[3].lastDate);

        auto convs2 = Conversation.getByTag("inbox", 2, 0);
        assert(convs2.length == 2);
        assert(convs2[0].dbId == convs[0].dbId);
        assert(convs2[1].dbId == convs[1].dbId);

        auto convs3 = Conversation.getByTag("inbox", 2, 1);
        assert(convs3.length == 2);
        assert(convs3[0].dbId == convs[2].dbId);
        assert(convs3[1].dbId == convs[3].dbId);

        auto convs4 = Conversation.getByTag("inbox", 1000, 0);
        assert(convs4[0].dbId == convs[0].dbId);
        assert(convs4[1].dbId == convs[1].dbId);
        assert(convs4[2].dbId == convs[2].dbId);
        assert(convs4[3].dbId == convs[3].dbId);

    }

    unittest // upsert
    {
        writeln("Testing upsert");
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                               "testemails");
        auto email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                                     getConfig().attachmentStore);
        auto emailObjectDate = BsonDate(SysTime(email.date,
                                                TimeZone.getTimeZone("GMT")))
                                               .toString;

        auto userId = getUserIdFromAddress(email.getHeader("to").addresses[0]);
        bool[string] tags = ["inbox": true, "dontstore": false, "anothertag": true];
        // test1: insert as is, should create a new conversation with this email as single member
        auto emailId = email.store();
        auto convId = Conversation.upsert(email, emailId, userId, tags).dbId;
        auto convDoc = collection("conversation").findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type      == Bson.Type.array);
        assert(convDoc.links.length    == 1);
        assert(bsonStr(convDoc.links[0]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[0].emailId)       == emailId);
        assert(convDoc.tags.type == Bson.Type.Array);
        assert(convDoc.tags.length == 2);
        assert(bsonStrArray(convDoc.tags)[0] == "inbox");
        assert(bsonStrArray(convDoc.tags)[1] == "anothertag");
        assert(bsonStr(convDoc.lastDate) == emailObjectDate);

        auto convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == userId);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[0].messageId == email.getHeader("message-id").addresses[0]);
        assert(convObject.links[0].emailDbId == emailId);
        assert(!convObject.attachFileNames.length);


        // test2: insert as a msgid of a reference already on a conversation, check that the right
        // conversationId is returned and the emailId added to its entry in the conversation.links
        recreateTestDb();
        email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        email.headers["message-id"].addresses[0] = "testreference@blabla.testdomain.com";
        emailId = email.store();
        convId = Conversation.upsert(email, emailId, userId, tags).dbId;
        convDoc = collection("conversation").findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 3);
        assert(bsonStr(convDoc.links[1]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != emailObjectDate);

        convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == userId);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[1].messageId == email.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].emailDbId == emailId);
        assert(!convObject.attachFileNames.length);

        // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
        // is added to that conversation
        recreateTestDb();
        email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
        email.addHeader(refHeader);
        emailId = email.store();
        convId = Conversation.upsert(email, emailId, userId, tags).dbId;
        convDoc = collection("conversation").findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 2);
        assert(bsonStr(convDoc.links[1]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != emailObjectDate);

        convObject = Conversation.get(convId);
        assert(convObject !is null);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == userId);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[1].messageId == email.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].emailDbId == emailId);
        assert(convObject.attachFileNames.length == 1);
        assert(convObject.attachFileNames[0] == "C++ Pocket Reference.pdf");
    }

    unittest // Conversation.getByReferences
    {
        writeln("Testing Conversation.getByReferences");
        recreateTestDb();
        auto userId1 = getUserIdFromAddress("testuser@testdatabase.com");
        auto userId2 = getUserIdFromAddress("anotherUser@testdatabase.com");
        assert(userId1.length);
        assert(userId2.length);

        auto conv = Conversation.getByReferences(userId1, ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2013-05-27T05:42:30Z");
        assert(conv.tags.length == 1);
        assert(conv.tags[0] == "inbox");
        assert(conv.links.length == 2);
        assert(conv.links[1].messageId == "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[1].emailDbId.length);


        conv = Conversation.getByReferences(userId2, ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tags.length == 1);
        assert(conv.tags[0] == "inbox");
        assert(conv.links.length == 1);
        assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
    }
}
