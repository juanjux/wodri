module webbackend.api;

import db.conversation;
import db.email;
import db.mongo;
import db.user;
import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.string;
import std.typecons;
import vibe.core.log;
import vibe.http.common;
import vibe.http.server;
import vibe.web.common;
import webbackend.apiconversation;
import webbackend.apiconversationsummary;
import webbackend.apiemail;
import webbackend.constants;

struct ApiSearchResult
{
    ApiConversationSummary[] conversations;
    ulong totalResultCount;
    ulong startIndex;
}


@rootPathFromName
final interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ApiConversationSummary[] getTagConversations(string id,
                                                 uint limit=DEFAULT_CONVERSATIONS_LIMIT,
                                                 uint page=0,
                                                 int loadDeleted=0);

    @method(HTTPMethod.GET) @path("conversation/")
    ApiConversation getConversation_(string id);

    @method(HTTPMethod.GET) @path("conversationdelete/")
    void deleteConversation(string id, int purge=0);

    @method(HTTPMethod.GET) @path("conversationundelete/")
    void unDeleteConversation(string id);

    @method(HTTPMethod.POST) @path("conversationaddtag/")
    void conversationAddTag(string id, string tag);

    @method(HTTPMethod.POST) @path("conversationremovetag/")
    void conversationRemoveTag(string id, string tag);

    @method(HTTPMethod.GET) @path("email/")
    ApiEmail getEmail(string id);

    @method(HTTPMethod.GET) @path("emaildelete/")
    void deleteEmail(string id, int purge=0);

    @method(HTTPMethod.GET) @path("emailundelete/")
    void unDeleteEmail(string id);

    @method(HTTPMethod.GET) @path("raw/")
    string getOriginalEmail(string id);

    @method(HTTPMethod.POST) @path("search/")
    ApiSearchResult search(string[] terms,
                                    string dateStart="",
                                    string dateEnd="",
                                    uint limit=DEFAULT_SEARCH_RESULTS_LIMIT,
                                    uint page=0,
                                    int loadDeleted=0);

    @method(HTTPMethod.POST) @path("draft/")
    string updateDraft(ApiEmail draftContent,
                       string userName, 
                       string replyDbId = "");

    version(db_usetestdb)
    {
        @method(HTTPMethod.GET) @path("testrebuilddb/")
        void testRebuildDb();
    }

}


final class ApiImpl: Api
{
    override:
        /** Returns an ApiConversationSummary for every Conversation in the tag */
        ApiConversationSummary[] getTagConversations(string id,
                                                     uint limit=DEFAULT_CONVERSATIONS_LIMIT,
                                                     uint page=0,
                                                     int loadDeleted=0)
        {
            ApiConversationSummary[] ret;
            auto conversations = Conversation.getByTag(
                    id,
                    limit,
                    page,
                    cast(Flag!"WithDeleted")loadDeleted
            );

            foreach(ref conv; conversations)
            {
                auto apiConvSummary = new ApiConversationSummary(conv,
                                                                 cast(bool)loadDeleted);
                if (apiConvSummary.numMessages > 0) // if == 0 all msgs were deleted
                    ret ~= apiConvSummary;
            }
            return ret;
        }


        ApiConversation getConversation_(string id)
        {
            auto conv = Conversation.get(id);
            return conv is null? null: new ApiConversation(conv);
        }


        void deleteConversation(string id, int purge=0)
        {
            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            if (purge != 0)
            {
                foreach(const link; conv.receivedLinks)
                    Email.removeById(link.emailDbId, No.UpdateConversation);
                conv.remove();
                return;
            }

            // set "deleted" tag and set all links to deleted.
            foreach(link; conv.receivedLinks)
            {
                Email.setDeleted(link.emailDbId, true, No.UpdateConversation);
                link.deleted = true;
            }
            conv.addTag("deleted");

            // update the conversation with the new tag and links on DB
            conv.store();
        }


        void unDeleteConversation(string id)
        {
            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            // undelete the email links and the emails
            foreach(link; conv.receivedLinks)
            {
                Email.setDeleted(link.emailDbId, false, No.UpdateConversation);
                link.deleted = false;
            }
            conv.removeTag("deleted");
            conv.store();
        }


        void conversationAddTag(string id, string tag)
        {
            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            conv.addTag(tag);
            conv.store();
        }


        void conversationRemoveTag(string id, string tag)
        {
            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            conv.removeTag(tag);
            conv.store();
        }


        ApiEmail getEmail(string id)
        {
            return Email.getApiEmail(id);
        }


        void deleteEmail(string id, int purge=0)
        {
            if (purge != 0)
                Email.removeById(id);
            else
                Email.setDeleted(id, true);
        }


        void unDeleteEmail(string id)
        {
            Email.setDeleted(id, false, Yes.UpdateConversation);
        }


        string getOriginalEmail(string id)
        {
            return Email.getOriginal(id);
        }


        ApiSearchResult search(string[] terms,
                                        string dateStart="",
                                        string dateEnd="",
                                        uint limit=DEFAULT_SEARCH_RESULTS_LIMIT,
                                        uint page=0,
                                        int loadDeleted = 0)
        {
            ApiSearchResult ret;
            ApiConversationSummary[] convs;

            if (limit <= 0 || page < 0)
            {
                logWarn("Api.search: returning empty array because limit<=0 or page<0");
                return ret;
            }

            auto results = Email.search(terms, dateStart, dateEnd);

            foreach(ref result; results)
            {
                assert(result.conversation !is null);
                auto apiConvSummary = new ApiConversationSummary(result.conversation,
                                                                 cast(bool)loadDeleted);
                if (apiConvSummary.numMessages > 0)
                    // all msgs had deleted=True
                    convs ~= apiConvSummary; 
            }

            auto convsArrayEnd   = convs.length;
            auto rangeStart      = min(limit*page,         convsArrayEnd);
            auto rangeEnd        = min(rangeStart + limit, convsArrayEnd);
            ret.conversations    = convs[rangeStart..rangeEnd];
            ret.totalResultCount = convsArrayEnd;
            ret.startIndex       = rangeStart;
            return ret;
        }


        // FIXME: get the authenticated user, remove it as a parameter for the call
        string updateDraft(ApiEmail draftContent, 
                string userName,
                string replyDbId = "")
        {
            auto dbEmail  = new Email(draftContent, replyDbId);
            auto addrUser = User.getFromAddress(dbEmail.from.addresses[0]);
            auto authUser = User.getFromLoginName(userName);

            if (addrUser is null)
                return "ERROR: no user found for the address " ~ dbEmail.from.addresses[0];
            if (authUser is null)
                return "ERROR: no user found in the DB with name: " ~ userName;
            if (addrUser.id != authUser.id)
                return format("ERROR: email user (%s) and authenticated user (%s) dont match",
                              addrUser.loginName, authUser.loginName);
            dbEmail.userId = addrUser.id;

            auto insertNew = draftContent.dbId.length == 0 ? Yes.ForceInsertNew
                                                           : No.ForceInsertNew;
            dbEmail.draft = true;
            dbEmail.store(insertNew);

            if (insertNew) // add to the conversation
                Conversation.upsert(dbEmail, [], []);
            return dbEmail.dbId;
        }


        version(db_usetestdb)
        {
            void testRebuildDb()
            {
                import db.test_support;
                recreateTestDb();
            }
        }

}
