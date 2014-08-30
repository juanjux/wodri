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
import vibe.internal.meta.funcattr;
import vibe.web.common;
import webbackend.apiconversation;
import webbackend.apiconversationsummary;
import webbackend.apiemail;
import webbackend.constants;
import webbackend.utils;

struct ApiSearchResult
{
    ApiConversationSummary[] conversations;
    ulong totalResultCount;
    ulong startIndex;
}


string getRequestUser(HTTPServerRequest req, HTTPServerResponse res)
{
    return req.username;
}

@rootPathFromName
interface Message
{
    @path("/:id/")
    @before!getRequestUser("_userName")
    ApiEmail get(string _userName, string _id);

    @path("/:id/raw/")
    @before!getRequestUser("_userName")
    string getRaw(string _userName, string _id);

    @path("/")
    @before!getRequestUser("_userName")
    string post(string _userName, ApiEmail draftContent, string replyDbId = "");

    @method(HTTPMethod.DELETE)
    @path("/:id/")
    @before!getRequestUser("_userName")
    void deleteEmail(string _userName, string _id, int purge=0);

    @method(HTTPMethod.PUT) @path(":id/undo/delete/")
    @before!getRequestUser("_userName")
    void unDeleteEmail(string _userName, string _id);

    @method(HTTPMethod.PUT) @path(":id/attachment/")
    @before!getRequestUser("_userName")
    string putAttachment(string _userName,
                         string _id,
                         ApiAttachment attachment,
                         string base64Content);

    @method(HTTPMethod.DELETE) @path(":id/attachment/")
    @before!getRequestUser("_userName")
    void deleteAttachment(string _userName, string _id, string attachmentId);
}


@rootPathFromName
interface Search
{
    @method(HTTPMethod.POST) @path("/")
    @before!getRequestUser("_userName")
    ApiSearchResult search(
            string _userName,
            string[] terms,
            string dateStart="",
            string dateEnd="",
            uint limit=DEFAULT_SEARCH_RESULTS_LIMIT,
            uint page=0,
            int loadDeleted=0
    );
}


@rootPathFromName
interface Conv
{
    @path("/:id/")
    @before!getRequestUser("_userName")
    ApiConversation get(string _userName, string _id);

    @method(HTTPMethod.DELETE) @path("/:id/")
    @before!getRequestUser("_userName")
    void deleteConversation(string _userName, string _id, int purge=0);

    // Undelete (if not previously purged!)
    @method(HTTPMethod.PUT) @path(":id/undo/delete/")
    @before!getRequestUser("_userName")
    void unDeleteConversation(string _userName, string _id);

    // Get conversations with the tag ":id"  (its not really an id but a tagname)
    @method(HTTPMethod.GET) @path("tag/:id/")
    @before!getRequestUser("_userName")
    ApiConversationSummary[] getTagConversations(string _id,
                                                 string _userName,
                                                 uint limit=DEFAULT_CONVERSATIONS_LIMIT,
                                                 uint page=0,
                                                 int loadDeleted=0);


    // Add a tag to the conversation
    @method(HTTPMethod.POST) @path(":id/tag/")
    @before!getRequestUser("_userName")
    void conversationAddTag(string _userName, string _id, string tag);

    // Removed a tag from a conversation
    @method(HTTPMethod.DELETE) @path(":id/tag/")
    @before!getRequestUser("_userName")
    void conversationRemoveTag(string _userName, string _id, string tag);
}


@rootPathFromName
interface Test
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
        ApiEmail get(string userName, string id)
        {
            return Email.isOwnedBy(id, userName) ? new ApiEmail(Email.get(id))
                                                 : null;
        }


        string getRaw(string userName, string id)
        {
            return Email.isOwnedBy(id, userName) ? Email.getOriginal(id)
                                               : null;
        }


        string post(string userName, ApiEmail draftContent, string replyDbId = "")
        {
            auto dbEmail  = new Email(draftContent, replyDbId);
            // XXX add a new call to compare two with a single roundtrip
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
            dbEmail.store(insertNew, No.StoreAttachMents);

            if (insertNew) // add to the conversation
                Conversation.upsert(dbEmail, [], []);
            return dbEmail.dbId;
        }


        void deleteEmail(string userName, string id, int purge=0)
        {
            if (!Email.isOwnedBy(id, userName))
                return;

            if (purge)
                Email.removeById(id);
            else
                Email.setDeleted(id, true);
        }


        void unDeleteEmail(string userName, string id)
        {
            if (Email.isOwnedBy(id, userName))
                Email.setDeleted(id, false, Yes.UpdateConversation);
        }


        string putAttachment(string userName,
                             string id,
                             ApiAttachment attachment,
                             string base64Content)
        {
            return Email.isOwnedBy(id, userName)
                                    ? Email.addAttachment(id, attachment, base64Content)
                                    : "";
        }


        void deleteAttachment(string userName, string id, string attachmentId)
        {
            if (Email.isOwnedBy(id, userName))
                Email.deleteAttachment(id, attachmentId);
        }

}


final class SearchImpl : Search
{
override:
        ApiSearchResult search(
                string userName,
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

            immutable userId = User.getIdFromLoginName(userName);
            if (!userId.length)
            {
                logWarn("Wrong user: ", userName);
                return ret;
            }

            if (limit <= 0 || page < 0)
            {
                logWarn("Api.search: returning empty array because limit<=0 or page<0");
                return ret;
            }

            auto results = Email.search(terms, userId, dateStart, dateEnd);
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


final class ConvImpl : Conv
{
override:
        ApiConversation get(string userName, string id)
        {
            if (Conversation.isOwnedBy(id, userName))
            {
                auto conv = Conversation.get(id);
                if (conv !is null)
                    return new ApiConversation(conv);
            }
            return null;
        }


        void deleteConversation(string userName, string id, int purge=0)
        {
            if (!Conversation.isOwnedBy(id, userName))
                return;

            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            if (purge)
            {
                foreach(const link; conv.receivedLinks)
                    Email.removeById(link.emailDbId, No.UpdateConversation);
                conv.remove();
                return;
            }
            // do not purge, just add the deleted tag and set emails as deleted
            else
            {

                foreach(link; conv.receivedLinks)
                {
                    Email.setDeleted(link.emailDbId, true, No.UpdateConversation);
                    link.deleted = true;
                }
                conv.addTag("deleted");
                conv.store();
            }
        }


        void unDeleteConversation(string userName, string id)
        {
            if (!Conversation.isOwnedBy(id, userName))
                return;

            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            // undelete the email links and the emails
            foreach(link; conv.receivedLinks)
            {
                Email.setDeleted(link.emailDbId,
                                        false,
                                        No.UpdateConversation);
                link.deleted = false;
            }
            conv.removeTag("deleted");
            conv.store();
        }


        /** Returns an ApiConversationSummary for every Conversation in the tag */
        ApiConversationSummary[] getTagConversations(string id,
                                                     string userName,
                                                     uint limit=DEFAULT_CONVERSATIONS_LIMIT,
                                                     uint page=0,
                                                     int loadDeleted=0)
        {
            ApiConversationSummary[] ret;
            auto conversations = Conversation.getByTag(
                    id,
                    User.getIdFromLoginName(userName),
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


        void conversationAddTag(string userName, string id, string tag)
        {
            if (!Conversation.isOwnedBy(id, userName))
                return;

            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            conv.addTag(tag);
            conv.store();
        }


        void conversationRemoveTag(string userName, string id, string tag)
        {
            if (!Conversation.isOwnedBy(id, userName))
                return;

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
