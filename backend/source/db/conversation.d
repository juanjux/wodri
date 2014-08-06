module db.conversation;

import std.string;
import std.path;
import std.algorithm;
import std.stdio;
import std.regex;
import std.typecons;
import core.time: TimeException;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import vibe.core.log;
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

    private bool hasLink(string messageId, string emailDbId)
    {
        foreach(ref link; this.links)
            if (link.messageId == messageId && link.emailDbId == emailDbId)
                return true;
        return false;
    }
    /** Adds a new link (email in the thread) to the conversation */
    void addLink(string messageId, string emailDbId="", bool deleted=false)
    {
        assert(messageId.length);
        if (!messageId.length)
            throw new Exception("Conversation.addLink: First MessageId parameter " ~ 
                                "must have length");
        if (!hasLink(messageId, emailDbId))
            this.links ~= MessageLink(messageId, emailDbId, deleted);
    }


    // FIXME: ugly copy of the entire links list, I probably should use some container
    // with fast removal or this could have problems with threads with hundreds of messages
    // FIXME: update this.lastDate
    void removeLink(string emailDbId)
    {
        assert(emailDbId.length);
        if (!emailDbId.length)
            throw new Exception("Conversation.removeLink must receive an emailDbId ");

        MessageLink[] newLinks;
        foreach(link; this.links)
            if (link.emailDbId != emailDbId)
                newLinks ~= link;
        this.links = newLinks;
    }


    /** Update the lastDate field if the argument is newer*/
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
            this.tags, linksApp.data);
    }

    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================
    
    // XXX error control
    void store()
    {
        auto bson = parseJsonString(this.toJson);
        collection("conversation").update(["_id": this.dbId], bson, UpdateFlags.Upsert);
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
    static Conversation getByReferences(string userId, const string[] references, 
                                        Flag!"WithDeleted" withDeleleted = No.WithDeleted)
    {
        string[] reversed = references.dup;
        reverse(reversed);
        Appender!string jsonApp;
        jsonApp.put(format(`{"userId":"%s","links.message-id":{"$in":%s},`,
                           userId, reversed));
        if (!withDeleleted)
            jsonApp.put(`"tags": {"$nin": ["deleted"]},`);
        jsonApp.put("}");

        auto bson = parseJsonString(jsonApp.data);
        auto convDoc = collection("conversation").findOne(bson);
        return convDoc.isNull? null: conversationDocToObject(convDoc);
    }


    static Conversation[] getByTag(string tagName, uint limit, uint page,
                                   Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        Conversation[] ret;

        Appender!string jsonApp;
        jsonApp.put(format(`{"tags": {"$in": ["%s"]},`, tagName));
        if (!withDeleted)
            jsonApp.put(`"tags":{"$nin":["deleted"]},`);
        jsonApp.put("}");

        auto bson   = parseJsonString(jsonApp.data);
        auto cursor = collection("conversation").find(bson,
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


    static void addTag(string dbId, string tag)
    {
        assert(dbId.length);
        assert(tag.length);

        auto json = format(`{"$push":{"tags":"%s"}}`, tag);
        auto bson = parseJsonString(json);
        collection("conversation").update(["_id": dbId], bson);
    }


    static void removeTag(string dbId, string tag)
    {
        assert(dbId.length);
        assert(tag.length);

        auto json = format(`{"$pull":{"tags":"%s"}}`, tag);
        auto bson = parseJsonString(json);
        collection("conversation").update(["_id": dbId], bson);
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


    // Find any conversation with this email and update the links.[email].deleted field
    package static string setEmailDeleted(string dbId, bool setDel)
    {
        auto json    = format(`{"links.emailId": {"$in": ["%s"]}}`, dbId);
        auto bson    = parseJsonString(json);
        auto convDoc = collection("conversation").findOne(bson,
                                                          ["_id": 1, "links": 1],
                                                          QueryFlags.None);
        if (convDoc.isNull)
        {
            logWarn(format("setEmailDeleted: No conversation found for email with id (%s)", dbId));
            return "";
        }

        int idx = 0;
        foreach(ref entry; convDoc.links)
        {
            if (!entry.emailId.isNull && bsonStr(entry.emailId) == dbId)
            {
                if (entry.deleted.isNull || bsonBool(entry.deleted) == setDel)
                {
                    logWarn(format("setEmailDeleted: entry for email (%s) in conversation is " ~
                                "null or the deleted state was already %s", dbId, setDel));
                    return "";
                }
                json = format(`{"$set": {"links.%d.deleted": %s}}`, idx, setDel);
                bson = parseJsonString(json);
                collection("conversation").update(["_id": bsonStr(convDoc._id)], bson);
                break;
            }
            idx++;
        }
        return bsonStr(convDoc._id);
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

    unittest // Conversation.remove
    {
        writeln("Testing Conversation.remove");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length == 4);
        const id = convs[0].dbId;
        convs[0].remove();
        convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length == 3);
        foreach(conv; convs)
            assert(conv.dbId != id);
    }

    unittest // Conversation.hasLink
    {
        writeln("Testing Conversation.hasLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", 0, 0)[0];
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
        auto conv = Conversation.getByTag("inbox", 0, 0)[0];
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
        auto conv = Conversation.getByTag("inbox", 0, 0)[1];
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

    unittest // Conversation.setEmailDeleted
    {
        writeln("Testing Conversation.setEmailDeleted");
        recreateTestDb();

        auto conv = Conversation.getByTag("inbox", 0, 0)[0];
        conv.setEmailDeleted(conv.links[0].emailDbId, true);
        conv = Conversation.getByTag("inbox", 0, 0)[0];
        assert(conv.links[0].deleted);
        conv.setEmailDeleted(conv.links[0].emailDbId, false);
        conv = Conversation.getByTag("inbox", 0, 0)[0];
        assert(!conv.links[0].deleted);
    }

    unittest // Conversation.remove
    {
        writeln("Testing Conversation.remove");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length == 4);
        auto copyConvs = convs.dup;
        convs[0].remove();
        auto newconvs = Conversation.getByTag("inbox", 0, 0);
        assert(newconvs.length == 3);
        assert(newconvs[0].dbId == copyConvs[1].dbId);
        assert(newconvs[1].dbId == copyConvs[2].dbId);
        assert(newconvs[2].dbId == copyConvs[3].dbId);
    }

    unittest // Conversation.store
    {
        writeln("Testing Conversation.store");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length == 4);
        // update existing (id doesnt change)
        convs[0].tags ~= "newtag";
        convs[0].addLink("someMessageId");
        auto oldDbId = convs[0].dbId;
        convs[0].store();

        auto convs2 = Conversation.getByTag("inbox", 0, 0);
        assert(convs2.length == 4);
        assert(convs2[0].dbId == oldDbId);
        assert(convs2[0].tags == ["inbox", "newtag"]);
        assert(convs2[0].links[1].messageId == "someMessageId");

        // create new (new dbId)
        convs2[0].dbId = BsonObjectID.generate().toString;
        convs2[0].store();
        auto convs3 = Conversation.getByTag("inbox", 0, 0);
        assert(convs3.length == 5);

        bool found = false;
        foreach(conv; convs3)
        {
            if (conv.dbId == convs2[0].dbId)
            {
                found = true;
                assert(conv.userDbId == convs2[0].userDbId);
                assert(conv.lastDate == convs2[0].lastDate);
                assert(conv.tags.length == convs2[0].tags.length);
                assert(conv.tags[0] == convs2[0].tags[0]);
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

        // check that it doesnt returns the deleted convs
        auto len1 = convs4.length;
        Conversation.addTag(convs4[0].dbId, "deleted");
        convs4 = Conversation.getByTag("inbox", 1000, 0);
        assert(convs4.length == len1-1);
        // except when using Yes.WithDeleted
        convs4 = Conversation.getByTag("inbox", 1000, 0, Yes.WithDeleted);
        assert(convs4.length == len1);
    }

    unittest // Conversation.addTag / removeTag
    {
        writeln("Testing Conversation.addTag");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", 0, 0);
        assert(convs.length);
        auto dbId = convs[0].dbId;
        Conversation.addTag(dbId, "testTag");
        auto conv = Conversation.get(dbId);
        assert(conv !is null);
        assert(countUntil(conv.tags, "testTag"));

        writeln("Testing Conversation.removeTag");
        Conversation.removeTag(dbId, "testTag");
        conv = Conversation.get(dbId);
        assert(countUntil(conv.tags, "testTag") == -1);
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

        Conversation.addTag(conv.dbId, "deleted");
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

    unittest // clearSubject
    {
        writeln("Testing conversation.clearSubject");
        assert(clearSubject("RE: polompos") == "polompos");
        assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
        assert(clearSubject("Pok and something Re: things") == "Pok and something things");
    }
}
