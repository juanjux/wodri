module db.conversation;

import std.datetime;
import std.string;
import std.datetime;
import core.time: TimeException;
import vibe.data.bson;
import db.mongo;

struct MessageLink
{
    string messageId;
    string emailDbId;
}

struct Conversation
{
    string dbId;
    string userDbId;
    string lastDate;
    string[] tags;
    MessageLink[] links;
    string[] attachFileNames;
    string cleanSubject;

    static Conversation load(string id)
    {
        auto convDoc = collection("conversation").findOne(["_id": id]);
        return conversationDocToObject(convDoc);
    }

    static private Conversation conversationDocToObject(ref Bson convDoc)
    {
        Conversation ret;
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
            "cleanSubject": "%s",
            "tags": %s,
            "links": [%s]
        }`, this.dbId, this.userDbId, 
            this.lastDate, this.cleanSubject,
            to!string(this.tags), linksApp.data);
    }
}
