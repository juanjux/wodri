module db.mongo.driverconversationmongo;


version(MongoDriver)
{
import common.utils;
import db.config: getConfig;
import db.conversation: Conversation;
import db.dbinterface.driverconversationinterface;
import db.email;
import db.mongo.mongo;
import db.user: User;
import std.algorithm;
import std.path;
import std.regex;
import std.string;
import std.typecons;
import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;

final class DriverConversationMongo : DriverConversationInterface
{
    private static Conversation docToObject(const ref Bson convDoc)
    {
        if (convDoc.isNull)
            return null;

        assert(!convDoc.links.isNull);

        auto ret         = new Conversation();
        ret.id         = bsonStr(convDoc._id);
        ret.userDbId     = bsonStr(convDoc.userId);
        ret.lastDate     = bsonStr(convDoc.lastDate);
        ret.cleanSubject = bsonStr(convDoc.cleanSubject);

        foreach(tag; bsonStrArray(convDoc.tags))
            ret.addTag(tag);

        foreach(link; convDoc.links)
        {
            immutable emailId = bsonStr(link["emailId"]);
            const attachNames = bsonStrArraySafe(link["attachNames"]);
            ret.addLink(bsonStr(link["message-id"]), attachNames, emailId, bsonBool(link["deleted"]));
        }
        return ret;
    }

    version(unittest)
    {
        static void addTagDb(in string id, in string tag)
        {
            assert(id.length);
            assert(tag.length);

            auto json = format(`{"$push":{"tags":"%s"}}`, tag);
            auto bson = parseJsonString(json);
            collection("conversation").update(["_id": id], bson);
        }

        static void removeTagDb(in string id, in string tag)
        {
            assert(id.length);
            assert(tag.length);

            auto json = format(`{"$pull":{"tags":"%s"}}`, tag);
            auto bson = parseJsonString(json);
            collection("conversation").update(["_id": id], bson);
        }
    }

override:
    const(EmailAndConvIds[]) searchEmails(in string[] needles,
                                          in string userId,
                                          in string dateStart = "",
                                          in string dateEnd = "")
    in
    {
        assert(userId.length);
    }
    body
    {
        EmailAndConvIds[] res;
        foreach(needle; needles)
        {
            Appender!string findJson;
            findJson.put(format(`{"$text": {"$search": "\"%s\""}`, needle));

            findJson.put(format(`,"userId":%s`, Json(userId).toString));

            if (dateStart.length && dateEnd.length)
                findJson.put(format(`,"isoDate": {"$gt": %s, "$lt": %s}}`,
                                    Json(dateStart).toString,
                                    Json(dateEnd).toString));

            else if (dateStart.length && !dateEnd.length)
                findJson.put(format(`,"isoDate": {"$gt": %s}}`,
                                    Json(dateStart).toString));

            else if (dateEnd.length && !dateStart.length)
                findJson.put(format(`,"isoDate": {"$lt": %s}}`,
                                    Json(dateEnd).toString));

            else
                findJson.put("}");

            auto emailIdsCursor = collection("emailIndexContents").find(
                    parseJsonString(findJson.data),
                    ["emailDbId": 1, "convId": 1],
                    QueryFlags.None
            ).sort(["lastDate": -1]);

            foreach(item; emailIdsCursor)
                res ~= EmailAndConvIds(bsonStr(item.emailDbId), bsonStr(item.convId));
        }
        return removeDups(res);
    }


    /** Returns null if no Conversation with those references was found. */
    Conversation get(in string id)
    {
        immutable convDoc = findOneById("conversation", id);
        return convDoc.isNull ? null : docToObject(convDoc);
    }


    /**
     * Return the first Conversation that has ANY of the references contained in its
     * links. Returns null if no Conversation with those references was found.
     */
    Conversation getByReferences(in string userId,
                                 in string[] references,
                                 in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        string[] reversed = references.dup;
        reverse(reversed);
        Appender!string jsonApp;
        jsonApp.put(format(`{"userId":"%s","links.message-id":{"$in":%s},`,
                           userId, reversed));
        if (!withDeleted)
            jsonApp.put(`"tags":{"$nin": ["deleted"]}`);
        jsonApp.put("}");

        immutable convDoc = collection("conversation").findOne(parseJsonString(jsonApp.data));
        return docToObject(convDoc);
    }


    Conversation getByEmailId(in string emailId,
                              in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        Appender!string jsonApp;
        jsonApp.put(format(`{"links.emailId": {"$in": %s},`, [emailId]));
        if (!withDeleted)
            jsonApp.put(`"tags": {"$nin": ["deleted"]},`);
        jsonApp.put("}");

        immutable convDoc = collection("conversation").findOne(parseJsonString(jsonApp.data));
        return docToObject(convDoc);
    }


    Conversation[] getByTag(in string tagName,
                            in string userId,
                            in uint limit=0,
                            in uint page=0,
                            in Flag!"WithDeleted" withDeleted = No.WithDeleted)
    {
        Appender!string jsonApp;
        jsonApp.put(format(`{"tags": {"$in": [%s]},`, Json(tagName).toString));
        if (!withDeleted)
            jsonApp.put(`"tags":{"$nin":["deleted"]},`);
        jsonApp.put(format(`"userId": %s}`, Json(userId).toString));

        auto cursor = collection("conversation").find(
                parseJsonString(jsonApp.data),
                Bson(null),
                QueryFlags.None,
                page*limit // skip
        ).sort(["lastDate": -1]);
        cursor.limit(limit);

        Conversation[] ret;
        foreach(ref doc; cursor)
        {
            if (!doc.isNull)
                    ret ~= docToObject(doc);
        }
        return ret;
    }


    void store(Conversation conv)
    {
        collection("conversation").update(
                ["_id": conv.id],
                parseJsonString(conv.toJson),
                UpdateFlags.Upsert
        );
    }


    /** Note: this will remove the conversation AND purge its emails */
    void remove(Conversation conv)
    {
        if (!conv.id.length)
        {
            logWarn("DriverConversationMongo.remove: empty DB id, is this conversation stored?");
            return;
        }
        // purge the emails
        foreach(const ref link; conv.receivedLinks)
            Email.purgeById(link.emailDbId);
        // remove the conversation from DB
        collection("conversation").remove(["_id": conv.id]);
    }


    /**
     * Insert or update a conversation with this email messageId, references, tags
     * and date
     */
    Conversation addEmail(in Email email, in string[] tagsToAdd, in string[] tagsToRemove)
    in
    {
        assert(email.id.length);
        assert(email.userId.length);
    }
    body
    {
        const references     = email.getHeader("references").addresses;
        immutable messageId  = email.messageId;

        auto conv = Conversation.getByReferences(email.userId, references ~ messageId);
        if (conv is null)
            conv = new Conversation();
        conv.userDbId = email.userId;

        // date: will only be set if newer than lastDate
        conv.updateLastDate(email.isoDate);

        // tags
        conv.addTags(tagsToAdd);
        conv.removeTags(tagsToRemove);

        // add the email's references: addLink() only adds the new ones
        string[] empty;
        foreach(reference; references)
        {
            conv.addLink(reference, empty, Email.messageIdToDbId(reference), email.deleted);
        }

        bool wasInConversation = false;
        if (conv.id.length)
        {
            // existing conversation: see if this email msgid is on the conversation links,
            // (can happen if an email referring to this one entered the system before this
            // email); if so update the link with the full data we've now
            foreach(ref entry; conv.links)
            {
                if (entry.messageId == messageId)
                {
                    entry.emailDbId   = email.id;
                    entry.deleted     = email.deleted;
                    wasInConversation = true;
                    foreach(ref attach; email.attachments.list)
                    {
                        entry.attachNames ~= attach.filename;
                    }
                    break;
                }
            }
        }
        else
            conv.id = BsonObjectID.generate().toString;

        if (!wasInConversation)
        {
            // get the attachFileNames and add this email to the conversation
            const emailSummary = Email.getSummary(email.id);
            conv.addLink(messageId, emailSummary.attachFileNames, email.id, email.deleted);
        }

        // update the conversation cleaned subject (last one wins)
        if (email.hasHeader("subject"))
            conv.cleanSubject = clearSubject(email.getHeader("subject").rawValue);

        conv.store();

        // update the emailIndexContent reverse link to the Conversation
        // (for madz speed)
        const indexBson = parseJsonString(
                format(`{"$set": {"convId": "%s"}}`, conv.id)
        );
        collection("emailIndexContents").update(["emailDbId": email.id], indexBson);
        return conv;
    }


    bool isOwnedBy(in string convId, in string userName)
    {
        import db.user;
        immutable userId = User.getIdFromLoginName(userName);
        if (!userId.length)
            return false;

        immutable convDoc = collection("conversation").findOne(
                ["_id": convId, "userId": userId],
                ["_id": 1],
                QueryFlags.None
        );
        return !convDoc.isNull;
    }
}
} // end version(MongoDriver)
