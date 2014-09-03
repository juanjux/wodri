module db.conversation;

import common.utils;
import core.time: TimeException;
import db.config: getConfig;
import db.tagcontainer;
import std.algorithm;
import std.path;
import std.regex;
import std.stdio;
import std.string;
import std.typecons;
import vibe.core.log;
import vibe.data.bson;
version(MongoDriver)
{
    import db.mongo.mongo;
    import vibe.db.mongo.mongo;
}

struct MessageLink
{
    string messageId;
    string emailDbId;
    string[] attachNames;
    bool deleted;
}


final class Conversation
{
    import db.dbinterface.driverconversationinterface;
    private static DriverConversationInterface dbDriver = null;

    string dbId;
    string userDbId;
    string lastDate;

    MessageLink[] links;
    string cleanSubject;
    private TagContainer m_tags;

    bool     hasTag(in string tag) const { return m_tags.has(tag);  }
    bool     hasTags(in string[] tags) const { return m_tags.has(tags); }
    void     addTag(in string tag)           { m_tags.add(tag);         }
    void     removeTag(in string tag)        { m_tags.remove(tag);      }
    string[] tagsArray()            const { return m_tags.array;     }
    uint     numTags()              const { return m_tags.length;    }

    static this()
    {
        version(MongoDriver)
        {
            import db.mongo.driverconversationmongo;
            dbDriver = new DriverConversationMongo();
        }
    }

    bool hasLink(in string messageId, in string emailDbId)
    {
        foreach(ref link; this.links)
            if (link.messageId == messageId && link.emailDbId == emailDbId)
                return true;
        return false;
    }


    /** Adds a new link (email in the thread) to the conversation */
    // FIXME: update this.lastDate
    void addLink(in string messageId, in string[] attachNames, in string emailDbId="",
                 in bool deleted=false)
    {
        assert(messageId.length);
        if (!messageId.length)
        {
           throw new Exception("Conversation.addLink: First MessageId parameter " ~
                                "must have length");
        }

        if (!hasLink(messageId, emailDbId))
        {
            this.links ~= MessageLink(messageId, emailDbId, attachNames.dup, deleted);
        }
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
    package void updateLastDate(in string newIsoDate)
    nothrow
    {
        if (!this.lastDate.length || this.lastDate < newIsoDate)
            this.lastDate = newIsoDate;
    }

    version(MongoDriver)
    package string toJson()
    {
        auto linksApp = appender!string;
        foreach(const ref link; this.links)
            linksApp.put(format(`{"message-id": "%s",` ~
                                `"emailId": "%s",` ~
                                `"attachNames": %s,`
                                `"deleted": %s},`,
                                link.messageId,
                                link.emailDbId,
                                link.attachNames,
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

    // ==========================================================
    // Proxies for the dbDriver functions used outside this class
    // ==========================================================
    void store()
    {
        dbDriver.store(this);
    }


    // Note: this will NOT remove the contained emails from the DB 
    void remove()
    {
        dbDriver.remove(this.dbId);
    }


    /* Returns null if no Conversation with those references was found. */
    static Conversation get(in string id)
    {
        return dbDriver.get(id);
    }


    /**
     * Return the first Conversation that has ANY of the references contained in its
     * links. Returns null if no Conversation with those references was found.
     */
    static Conversation getByReferences(in string userId,
                                        in string[] references,
                                        in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        return dbDriver.getByReferences(userId, references, withDeleted);
    }


    static Conversation getByEmailId(in string emailId,
                                     in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        return dbDriver.getByEmailId(emailId, withDeleted);
    }


    static Conversation[] getByTag(in string tagName,
                                   in string userId,
                                   in uint limit=0,
                                   in uint page=0,
                                   in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        return dbDriver.getByTag(tagName, userId, limit, page, withDeleted);
    }


    /**
     * Insert or update a conversation with this email messageId, references, tags
     * and date
     */
    import db.email;
    static Conversation addEmail(in Email email,
                                 in string[] tagsToAdd,
                                 in string[] tagsToRemove)
    {
        return dbDriver.addEmail(email, tagsToAdd, tagsToRemove);
    }


    // Find any conversation with this email and update the links.[email].deleted field
    static string setEmailDeleted(in string dbId, in bool setDel)
    {
        return dbDriver.setEmailDeleted(dbId, setDel);
    }


    static bool isOwnedBy(string convId, string userName)
    {
        return dbDriver.isOwnedBy(convId, userName);
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
        string[] attachs = ["someAttachName", "anotherAttachName"];
        conv.addLink(emailMsgId, attachs, emailDbId, deleted);
        assert(conv.links.length == 1);
        assert(!conv.links[0].attachNames.length);

        // check that it adds a new link
        conv.addLink("someMessageId", attachs, "someEmailDbId", false);
        assert(conv.links.length == 2);
        assert(conv.links[1].messageId == "someMessageId");
        assert(conv.links[1].emailDbId == "someEmailDbId");
        assert(!conv.links[1].deleted);
        assert(conv.links[1].attachNames == attachs);
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

    unittest // Conversation.store
    {
        writeln("Testing Conversation.store");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        // update existing (id doesnt change)
        convs[0].addTag("newtag");
        string[] attachNames = ["one", "two"];
        convs[0].addLink("someMessageId", attachNames);
        auto oldDbId = convs[0].dbId;
        convs[0].store();

        auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs2.length == 3);
        assert(convs2[0].dbId == oldDbId);
        assert(convs2[0].hasTag("inbox"));
        assert(convs2[0].hasTag("newtag"));
        assert(convs2[0].numTags == 2);
        assert(convs2[0].links[1].messageId == "someMessageId");
        assert(convs2[0].links[1].attachNames == attachNames);

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
                assert(conv.links[0].attachNames == convs2[0].links[0].attachNames);
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

}
