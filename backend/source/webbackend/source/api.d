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
final interface Message
{
    ApiEmail get(string id);

    @path("/:id/raw/")
    string getRaw(string _id);

    @method(HTTPMethod.DELETE) @path("/:id/")
    void deleteEmail(string _id, int purge=0);

    @method(HTTPMethod.PUT) @path(":id/undo/delete/")
    void unDeleteEmail(string _id);
}


@rootPathFromName
final interface Search
{
    @method(HTTPMethod.POST) @path("/")
    ApiSearchResult search(
            string[] terms,
            string dateStart="",
            string dateEnd="",
            uint limit=DEFAULT_SEARCH_RESULTS_LIMIT,
            uint page=0,
            int loadDeleted=0
    );
}


@rootPathFromName
final interface Draft
{
    @method(HTTPMethod.POST) @path("/")
    string updateDraft(ApiEmail draftContent,
                       string userName, 
                       string replyDbId = "");
}


@rootPathFromName
final interface Conv
{
    ApiConversation get(string id);

    @method(HTTPMethod.DELETE) @path("/:id/")
    void deleteConversation(string _id, int purge=0);

    // Get conversations with the tag ":id"  (its not really an id but a tagname)
    @method(HTTPMethod.GET) @path("tag/:id/")
    ApiConversationSummary[] getTagConversations(string _id,
                                                 uint limit=DEFAULT_CONVERSATIONS_LIMIT,
                                                 uint page=0,
                                                 int loadDeleted=0);

    // Undelete (if not purged!)
    @method(HTTPMethod.PUT) @path(":id/undo/delete/")
    void unDeleteConversation(string _id);

    // Add a tag to the conversation
    @method(HTTPMethod.POST) @path(":id/tag/")
    void conversationAddTag(string _id, string tag);

    // Removed a tag from a conversation
    @method(HTTPMethod.DELETE) @path(":id/tag/")
    void conversationRemoveTag(string _id, string tag);
}


@rootPathFromName
final interface Test
{
    version(db_usetestdb)
    {
        @method(HTTPMethod.GET) @path("testrebuilddb/")
        void testRebuildDb();
    }
}


final class MessageImpl : Message
{
override:
        ApiEmail get(string id)
        {
            return Email.getApiEmail(id);
        }


        string getRaw(string id)
        {
            return Email.getOriginal(id);
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
}


final class SearchImpl : Search
{
override:
        ApiSearchResult search(
                string[] terms,
                string dateStart="",
                string dateEnd="",
                uint limit=DEFAULT_SEARCH_RESULTS_LIMIT,
                uint page=0,
                int loadDeleted = 0
        )
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
}

final class DraftImpl : Draft
{
override:
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


}

final class ConvImpl : Conv
{
override:
        ApiConversation get(string id)
        {
            auto conv = Conversation.get(id);
            return conv is null? null: new ApiConversation(conv);
        }


        void deleteConversation(string _id, int purge=0)
        {
            auto conv = Conversation.get(_id);
            if (conv is null)
                return;

            if (purge)
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


        void unDeleteConversation(string _id)
        {
            auto conv = Conversation.get(_id);
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

        /** Returns an ApiConversationSummary for every Conversation in the tag */
        ApiConversationSummary[] getTagConversations(string _id,
                                                     uint limit=DEFAULT_CONVERSATIONS_LIMIT,
                                                     uint page=0,
                                                     int loadDeleted=0)
        {
            ApiConversationSummary[] ret;
            auto conversations = Conversation.getByTag(
                    _id,
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
}


final class TestImpl: Test
{
    override:
        version(db_usetestdb)
        void testRebuildDb()
        {
            import db.test_support;
            recreateTestDb();
        }
}
