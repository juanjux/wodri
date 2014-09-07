module db.conversation;

import common.utils;
import core.time: TimeException;
import db.config: getConfig;
import db.tagcontainer;
import db.searchresult;
import db.email;
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

    string        dbId;
    string        userDbId;
    string        lastDate;
    MessageLink[] links;
    string        cleanSubject;
    private       TagContainer m_tags;

    bool     hasTag(in string tag) const     { return m_tags.has(tag);  }
    bool     hasTags(in string[] tags) const { return m_tags.has(tags); }
    void     addTag(in string tag)           { m_tags.add(tag);         }
    void     addTags(in string[] tags)       { m_tags.add(tags);        }
    void     removeTag(in string tag)        { m_tags.remove(tag);      }
    void     removeTags(in string[] tags)    { m_tags.remove(tags);     }
    string[] tagsArray() const               { return m_tags.array;     }
    uint     numTags() const                 { return m_tags.length;    }

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
        //string lastDate = "";

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


    /** NOTE: * - dateStart and dateEnd should be GMT */
    static const(SearchResult)[] search(in string[] needles,
                                        in string userId,
                                        in string dateStart="",
                                        in string dateEnd="")
    {
        import db.conversation;
        // Get an list of matching email IDs
        const matchingEmailAndConvIds = dbDriver.searchEmails(needles, userId,
                                                              dateStart, dateEnd);

        // keep the found conversations+matches indexes, the key is the conversation dbId
        SearchResult[string] map;

        // For every id, get the conversation (with MessageSummaries loaded)
        foreach(emailAndConvId; matchingEmailAndConvIds)
        {
            const conv = Conversation.get(emailAndConvId.convId);
            assert(conv !is null);

            uint indexMatching = -1;
            // find the index of the email inside the conversation
            foreach(int idx, const ref MessageLink link; conv.links)
            {
                if (link.emailDbId == emailAndConvId.emailId)
                {
                    indexMatching = idx;
                    break; // inner foreach
                }
            }
            assert(indexMatching != -1);

            if (conv.dbId in map)
                map[conv.dbId].matchingEmailsIdx ~= indexMatching;
            else
                map[conv.dbId] = SearchResult(conv, [indexMatching]);
        }
        return map.values;
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
                                `"attachNames": %s,` ~
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


    // Find any conversation with this email and update the links.[email].deleted field
    static string setLinkDeleted(in string emailDbId, in bool setDel)
    {
        Email.setDeleted(emailDbId, setDel);
        auto conv = getByEmailId(emailDbId);
        if (conv is null)
        {
            logWarn(format("setLinkDeleted: No conversation found for email with id (%s)",
                           emailDbId));
            return "";
        }

        foreach(ref entry; conv.links)
        {
            if (entry.emailDbId == emailDbId)
            {
                if (entry.deleted == setDel)
                {
                    logWarn(format("setLinkDeleted: delete state for email (%s) in " ~
                                   "conversation was already %s", emailDbId, setDel));
                }
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


    // remove the email and maybe the conversation if it was the only received email on it
    static void purgeLink(in string emailDbId)
    {
        Email.purgeById(emailDbId);
        auto conv = Conversation.getByEmailId(emailDbId);
        if (conv !is null)
        {
            conv.removeLink(emailDbId);
            if (conv.dbId.length) // will be 0 if it was removed from the DB
                conv.store();
        }
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
        dbDriver.remove(this);
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
    static Conversation addEmail(in Email email,
                                 in string[] tagsToAdd,
                                 in string[] tagsToRemove)
    {
        return dbDriver.addEmail(email, tagsToAdd, tagsToRemove);
    }


    static bool isOwnedBy(string convId, string userName)
    {
        return dbDriver.isOwnedBy(convId, userName);
    }
}
