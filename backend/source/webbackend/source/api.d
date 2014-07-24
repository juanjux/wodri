module webbackend.api;

import std.algorithm;
import std.typecons;
import std.array;
import std.conv;
import std.stdio;
import vibe.web.common;
import vibe.http.common;
import db.db;
import db.conversation;
import webbackend.apiconversationsummary;
import webbackend.apiconversation;
import webbackend.apiemail;


@rootPathFromName
interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ApiConversationSummary[] getTagConversations(string id, int limit=50, int page=0);

    @method(HTTPMethod.GET) @path("conversation/")
    ApiConversation getConversation_(string id);

    @method(HTTPMethod.GET) @path("email/")
    ApiEmail getEmail(string id);

    @method(HTTPMethod.GET) @path("raw/")
    string getRawEmail_(string id);
}


class ApiImpl: Api
{
    override:
        ApiConversationSummary[] getTagConversations(string id,
                                                     int limit=50,
                                                     int page=0)
        {
            // returns an ApiConversationSummary for every Conversation
            return getConversationsByTag(id, limit, page)
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

        string getRawEmail_(string id)
        {
            return getRawEmail(id);
        }
}
