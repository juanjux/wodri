module webbackend.api;

import std.algorithm;
import std.typecons;
import std.array;
import std.conv;
import std.stdio;

import vibe.web.common;
import vibe.http.common;

import db.mongo;
import db.conversation;
import db.email;

import webbackend.apiemail;
import webbackend.apiconversation;
import webbackend.apiconversationsummary;


@rootPathFromName
interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ApiConversationSummary[] getTagConversations(string id, int limit=50, int page=0);

    @method(HTTPMethod.GET) @path("conversation/")
    ApiConversation getConversation_(string id, int loadDeleted=0);

    @method(HTTPMethod.GET) @path("email/")
    ApiEmail getEmail(string id);

    @method(HTTPMethod.GET) @path("raw/")
    string getOriginalEmail(string id);
}


final class ApiImpl: Api
{
    override:
        ApiConversationSummary[] getTagConversations(string id,
                                                     int limit=50,
                                                     int page=0)
        {
            // returns an ApiConversationSummary for every Conversation
            return Conversation.getByTag(id, limit, page)
                   .map!(i => new ApiConversationSummary(i)).array;
        }


        ApiConversation getConversation_(string id, int loadDeleted=0)
        {
            return new ApiConversation(Conversation.get(id), cast(bool)loadDeleted);
        }


        ApiEmail getEmail(string id)
        {
            return Email.getApiEmail(id);
        }

        string getOriginalEmail(string id)
        {
            return Email.getOriginal(id);
        }
}
