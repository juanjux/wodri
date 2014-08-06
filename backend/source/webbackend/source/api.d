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
final interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ApiConversationSummary[] getTagConversations(string id, int limit=50, 
                                                 int page=0, int loadDeleted=0);

    @method(HTTPMethod.GET) @path("conversation/")
    ApiConversation getConversation_(string id);

    @method(HTTPMethod.GET) @path("conversationdelete/")
    void deleteConversation(string id, int purge=0);

    @method(HTTPMethod.GET) @path("conversationundelete/")
    void unDeleteConversation(string id);

    @method(HTTPMethod.GET) @path("email/")
    ApiEmail getEmail(string id);

    @method(HTTPMethod.GET) @path("emaildelete/")
    void deleteEmail(string id, int purge=0);

    @method(HTTPMethod.GET) @path("emailundelete/")
    void unDeleteEmail(string id);

    @method(HTTPMethod.GET) @path("raw/")
    string getOriginalEmail(string id);

    version(db_usetestdb)
    {
        @method(HTTPMethod.GET) @path("testrebuilddb/")
        void testRebuildDb();
    }

}


final class ApiImpl: Api
{
    override:
        ApiConversationSummary[] getTagConversations(string id,
                                                     int limit=50,
                                                     int page=0,
                                                     int loadDeleted=0)
        {
            // returns an ApiConversationSummary for every Conversation
            auto loadDel = cast(bool)loadDeleted? Yes.WithDeleted: No.WithDeleted;

            ApiConversationSummary[] ret;
            foreach(ref conv; Conversation.getByTag(id, limit, page, loadDel))
            {
                // Check if there is some not deleted email in the conversations; dont
                // return any ApiConversationSummary if the Conversation doesnt have any
                // undeleted emails
                bool hasNotDeleted = false;
                foreach(ref link; conv.links)
                {
                    if (!link.deleted)
                    {
                        hasNotDeleted = true;
                        break;
                    }
                }
                if (hasNotDeleted)
                    ret ~= new ApiConversationSummary(conv);
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
                foreach(ref link; conv.links)
                    Email.removeById(link.emailDbId, No.UpdateConversation);
                conv.remove();
                return;
            }


            // set "deleted" tag and set all links to deleted.
            foreach(ref link; conv.links)
            {
                Email.setDeleted(link.emailDbId, true, No.UpdateConversation);
                link.deleted = true;
            }

            // add the deleted tag is it wasnt already there
            if (countUntil(conv.tags, "deleted") == -1)
                conv.tags ~= "deleted";

            // update the conversation with the new tag and links on DB
            conv.store();
        }


        void unDeleteConversation(string id)
        {
            auto conv = Conversation.get(id);
            if (conv is null)
                return;

            // remove the "deleted" tag with marks the conversation as deleted
            conv.tags = remove!("a == \"deleted\"")(conv.tags);

            // undelete the email links and the emails
            foreach(ref link; conv.links)
            {
                Email.setDeleted(link.emailDbId, false, No.UpdateConversation);
                link.deleted = false;
            }
            conv.store();
        }


        ApiEmail getEmail(string id)
        {
            auto email = Email.getApiEmail(id);
            return email is null? null: email;
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

        version(db_usetestdb)
        {
            void testRebuildDb()
            {
                import db.test_support;
                recreateTestDb();
            }
        }

}
