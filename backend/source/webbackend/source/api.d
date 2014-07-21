module webbackend.api;

import std.algorithm;
import std.typecons;
import std.array;
import std.conv;
import std.stdio;
import vibe.web.common;
import vibe.http.common;
import retriever.db;
import retriever.conversation;
import webbackend.apiconversationsummary;
import webbackend.apiconversation;
import webbackend.apiemail;


@rootPathFromName
interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ApiConversationSummary[] getTagConversations(string name, int limit=50, int page=0);

    @method(HTTPMethod.GET) @path("conversation/")
    ApiConversation getConversation_(string id);

    @method(HTTPMethod.GET) @path("email/")
    ApiEmail getEmail(string id);
}


class ApiImpl: Api
{
    override:
        ApiConversationSummary[] getTagConversations(string name,
                                                     int limit=50,
                                                     int page=0)
        {
            // returns an ApiConversationSummary for every Conversation
            return getConversationsByTag(name, limit, page)
                   .map!(i => ApiConversationSummary(i)).array;
        }


        ApiConversation getConversation_(string id)
        {
            return ApiConversation(getConversation(id));
        }


        ApiEmail getEmail(string id)
        {
            return getApiEmail(id);
        }
}
