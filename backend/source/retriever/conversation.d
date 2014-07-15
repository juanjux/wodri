module retriever.conversation;

import std.datetime;
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

    void addLink(string messageId, string emailDbId)
    {
        this.links ~= MessageLink(messageId, emailDbId);
    }
}
