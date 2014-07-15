module retriever.conversation;

import std.datetime;
import std.string;
import vibe.data.bson;

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
    // XXX validate the newIsoDate
    void updateLastDate(string newIsoDate)
    {
        if (!this.lastDate.length || this.lastDate < newIsoDate)
            this.lastDate = newIsoDate;
    }


    string asJsonString()
    {
        auto linksApp = appender!string;
        foreach(link; this.links)
        {
            linksApp.put(format(`{"message-id": "%s", "emailId": "%s"},`, 
                                link.messageId, link.emailDbId));
        }
        return format(`
        {
            "_id": "%s",
            "userId": "%s",
            "lastDate": "%s",
            "tags": %s,
            "links": [%s]
        }`, this.dbId, this.userDbId, this.lastDate, to!string(this.tags), linksApp.data);
    }
}
