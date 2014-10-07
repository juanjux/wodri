module db.mongo.driveremailmongo;

version(MongoDriver)
{
import arsd.characterencodings: decodeBase64Stubborn;
import common.utils;
import db.attachcontainer: DbAttachment;
import db.config;
import db.dbinterface.driveremailinterface;
import db.email: Email, EmailSummary, TextPart;
import db.mongo.mongo;
import retriever.incomingemail: HeaderValue;
import std.file;
import std.path: baseName, buildPath, extension;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import vibe.inet.path: joinPath;
import webbackend.apiemail;

final class DriverEmailMongo : DriverEmailInterface
{
    // non-interface helpers

    /** Paranoic retrieval of emailDoc headers */
    // FIXME: should be private but the test_email.d need to have access for the unittests
    static string headerRaw(const ref Bson emailDoc, in string headerName)
    {
        if (!emailDoc.headers.isNull &&
            !emailDoc.headers[headerName].isNull &&
            !emailDoc.headers[headerName][0].rawValue.isNull)
            return bsonStr(emailDoc.headers[headerName][0].rawValue);
        return "";
    }

    // Get an email document, return the attachment filenames in an array
    // FIXME: should be private but the test_email.d need to have access for the unittests
    static string[] extractAttachNamesFromDoc(const ref Bson emailDoc)
    {
        string[] res;
        if (!emailDoc.isNull && !emailDoc.attachments.isNull)
        {
            foreach(ref attach; emailDoc.attachments)
            {
                immutable fName = bsonStrSafe(attach.fileName);
                if (fName.length)
                    res ~= fName;
            }
        }
        return res;
    }

    version(unittest)
    static auto getEmailCursorAtPosition(ulong pos)
    {
        auto cursor = collection("email").find();
        cursor.sort(["_id": 1]);
        assert(!cursor.empty);
        cursor.popFrontExactly(pos);
        return cursor;
    }


override: // interface methods

    Email get(in string id)
    {
        immutable emailDoc = findOneById("email", id);
        if (emailDoc.isNull || emailDoc.headers.isNull)
        {
            logWarn(format("Requested email with id %s is null or has null headers", id));
            return null;
        }

        auto ret               = new Email();
        ret.id                 = id;
        ret.userId             = bsonStr(emailDoc["userId"]);
        ret.deleted            = bsonBool(emailDoc["deleted"]);
        ret.draft              = bsonBool(emailDoc["draft"]);
        ret.sendRetries        = to!uint(bsonNumber(emailDoc["sendRetries"]));
        ret.forwardedTo        = bsonStrArraySafe(emailDoc["forwardedTo"]);
        ret.destinationAddress = bsonStr(emailDoc["destinationAddress"]);
        ret.messageId          = bsonStr(emailDoc["message-id"]);
        ret.from               = HeaderValue(bsonStrSafe(emailDoc["from"].rawValue),
                                             bsonStrArraySafe(emailDoc["from"].addresses));
        ret.receivers          = bsonStrArray(emailDoc["receivers"]);
        ret.rawEmailPath       = bsonStrSafe(emailDoc["rawEmailPath"]);
        ret.bodyPeek           = bsonStrSafe(emailDoc["bodyPeek"]);
        ret.isoDate            = bsonStr(emailDoc["isodate"]);

        switch(bsonStr(emailDoc["sendStatus"]))
        {
            case "PENDING"  : ret.sendStatus = SendStatus.PENDING;  break;
            case "RETRYING" : ret.sendStatus = SendStatus.RETRYING; break;
            case "FAILED"   : ret.sendStatus = SendStatus.FAILED;   break;
            case "SENT"     : ret.sendStatus = SendStatus.SENT;     break;
            default         : ret.sendStatus = SendStatus.NA;       break;
        }

        foreach(ref docHeader; emailDoc.headers)
        {
            foreach(ref headerItem; docHeader)
            {
                ret.headers.addField(
                    bsonStr(headerItem.name),
                    HeaderValue(bsonStr(headerItem.rawValue),
                                bsonStrArraySafe(headerItem.addresses))
                );
            }
        }

        // Attachments
        if (!emailDoc.attachments.isNull)
        {
            foreach(ref attach; emailDoc.attachments)
            {
                DbAttachment att;
                att.id      = bsonStr(attach.id);
                att.ctype     = bsonStrSafe(attach.contentType);
                att.filename  = bsonStrSafe(attach.fileName);
                att.contentId = bsonStrSafe(attach.contentId);
                att.size      = to!uint(bsonNumber(attach.size));
                att.realPath  = bsonStr(attach.realPath);
                ret.attachments.add(att);
            }
        }

        // Append all parts of the same type
        if (!emailDoc.textParts.isNull)
        {
            foreach(ref docTPart; emailDoc.textParts)
            {
                auto textPart = TextPart(
                        bsonStrSafe(docTPart.contentType),
                        bsonStrSafe(docTPart.content)
                );
                ret.textParts ~= textPart;
            }
        }
        return ret;
    }


    /**
     * Returns a smaller version of the standar email object
     */
    EmailSummary getSummary(in string id)
    in
    {
        assert(id.length);
    }
    body
    {
        auto res = new EmailSummary();
        immutable emailDoc = findOneById("email", id, "from", "headers", "isodate",
                                         "bodyPeek", "deleted", "draft", "attachments");

        if (!emailDoc.isNull)
        {
            res.id            = id;
            res.date            = headerRaw(emailDoc, "date");
            res.from            = bsonStr(emailDoc.from.rawValue);
            res.isoDate         = bsonStr(emailDoc.isodate);
            res.bodyPeek        = bsonStr(emailDoc.bodyPeek);
            res.deleted         = bsonBool(emailDoc.deleted);
            res.draft           = bsonBool(emailDoc.draft);
            res.attachFileNames = extractAttachNamesFromDoc(emailDoc);
        }
        return res;
    }


    string generateNewId()
    {
        auto id = BsonObjectID.generate().toString;
        return id;
    }


    bool isOwnedBy(in string emailId, in string userName)
    {
        import db.user;
        immutable userId = User.getIdFromLoginName(userName);
        if (!userId.length)
            return false;

        immutable emailDoc = collection("email").findOne(
                ["_id": emailId, "userId": userId], ["_id": 1], QueryFlags.None
        );
        return !emailDoc.isNull;
    }


    /** Adds an attachment to the email on the DB */
    string addAttachment(in string emailDbId,
                         in ApiAttachment apiAttach,
                         in string base64Content)
    {
        string attachId;

        if (apiAttach.id.length) // dont process attachs with a id set
        {
            logWarn("addAttachment was called with a non empty attachid."~
                    " emailId: " ~ emailDbId ~ " attachId: " ~ apiAttach.id);
            return attachId;
        }

        // check that the email exists on DB
        immutable emailDoc = findOneById("email", emailDbId);
        if (emailDoc.isNull)
        {
            logWarn("addAttachment, could find specified email: " ~ emailDbId);
            return attachId;
        }

        // decode the attachment and save the email
        immutable attContent = decodeBase64Stubborn(base64Content);
        if (!attContent.length)
        {
            logWarn("addAttachment: could not decode apiAttach \"" ~ apiAttach.filename ~
                    "\" for email with ID: " ~ emailDbId);
            return attachId;
        }

        immutable destFilePath = randomFileName(getConfig.absAttachmentStore,
                                                apiAttach.filename.extension);
        auto f = File(destFilePath, "w");
        f.rawWrite(attContent);

        // create the doc and insert into the email.attachments list on DB
        auto dbAttach      = DbAttachment(apiAttach);
        attachId           = BsonObjectID.generate().toString;
        dbAttach.id      = attachId;
        dbAttach.realPath  = destFilePath;
        dbAttach.size      = attContent.length;
        immutable pushJson = format(`{"$push": {"attachments": %s}}`, dbAttach.toJson);
        collection("email").update(["_id": emailDbId], parseJsonString(pushJson));
        return attachId;
    }


    /** Deletes an attachment from the DB and from the disk */
    void deleteAttachment(in string emailDbId, in string attachmentId)
    {
        if (!emailDbId.length || !attachmentId.length)
        {
            logWarn("deleteAttachment: email id or attachment id empty");
            return;
        }

        immutable emailDoc = findOneById("email", emailDbId, "_id", "attachments");
        if (emailDoc.isNull || emailDoc.attachments.isNull)
        {
            logWarn(format("deleteAttachment: delete for email [%s] and attach [%s] was " ~
                           "requested but email or attachments missing on DB",
                           emailDbId, attachmentId));
            return;
        }

        string filePath;
        bool found = false;
        foreach(ref attachDoc; emailDoc.attachments)
        {
            if (bsonStrSafe(attachDoc.id) == attachmentId)
            {
                found = true;
                filePath = bsonStrSafe(attachDoc.realPath);
                break;
            }
        }

        if (!found)
        {
            logWarn(format("deleteAttachment: email [%s] doesnt have an attachment with " ~
                           "id [%s]", emailDbId, attachmentId));
            return;
        }

        immutable json = format(
                `{"$pull": {"attachments": {"id": %s}}}`, Json(attachmentId).toString
        );
        collection("email").update(["_id": emailDbId], parseJsonString(json));

        if (filePath.length && filePath.exists)
            remove(filePath);
    }


    /** Returns the raw email as string */
    string getOriginal(in string id)
    {
        immutable emailDoc = findOneById("email", id, "rawEmailPath");
        if (!emailDoc.isNull && !emailDoc.rawEmailPath.isNull)
        {
            const rawPath = bsonStr(emailDoc.rawEmailPath);
            if (rawPath.length && rawPath.exists)
            {
                Appender!string app;
                auto rawFile = File(rawPath, "r");
                while(!rawFile.eof)
                    app.put(rawFile.readln());
                return app.data;
            }
        }
        return "ERROR: could not get raw email";
    }


    /**
     * Update the email DB record/document and set the deleted field to setDel
     */
    void setDeleted(in string id, in bool setDel)
    {

        // Get the email from the DB, check the needed deleted and userId fields
        immutable emailDoc = findOneById("email", id, "deleted");
        if (emailDoc.isNull || emailDoc.deleted.isNull)
        {
            logWarn(format("setDeleted: Trying to set deleted (%s) of email with " ~
                           "id (%s) not in DB or with missing deleted field", setDel, id));
            return;
        }

        immutable dbDeleted = bsonBool(emailDoc.deleted);
        if (dbDeleted == setDel)
        {
            logWarn(format("setDeleted: Trying to set deleted to (%s) but email "~
                           "with id (%s) already was in that state", setDel, id));
            return;
        }

        // Update the document
        immutable json = format(`{"$set": {"deleted": %s}}`, setDel);
        collection("email").update(["_id": id], parseJsonString(json));
    }


    /**
     * Completely remove the email from the DB. If there is any conversation
     * with this emailId as is its only link it will be removed too. The attachments
     * and the rawEmail files will be removed too.
     */
    void purgeById(in string id)
    {

        immutable emailDoc = findOneById("email", id, "_id", "attachments", "rawEmailPath");
        if (emailDoc.isNull)
        {
            logWarn(format("DriverEmailMongo.purgeById: Trying to remove email with id (%s) "~
                           " not in DB", id));
            return;
        }
        immutable emailId = bsonStr(emailDoc._id);
        immutable rawPath = bsonStrSafe(emailDoc.rawEmailPath);
        if (rawPath.length && rawPath.exists)
            std.file.remove(rawPath);

        if (!emailDoc.attachments.isNull)
        {
            foreach(ref attach; emailDoc.attachments)
            {
                immutable attachRealPath = bsonStrSafe(attach.realPath);
                if (attachRealPath.length && attachRealPath.exists)
                    std.file.remove(attachRealPath);
            }
        }
        // Remove the email from the DB
        collection("email").remove(["_id": emailId]);
    }


    void storeTextIndex(in Email email)
    in
    {
        assert(email.id.length);
    }
    body
    {
        if (!email.id.length)
        {
            logError("Email.storeTextIndex: trying to store an email index without email id");
            return;
        }

        // body
        immutable maybeText = email.maybeBodyNoFormat();

        // searchable headers (currently, to, from, cc, bcc and subject)
        Appender!string headerIndexText;
        headerIndexText.put("from:"~strip(email.from.rawValue)~"\n");
        foreach(hdrKey; HEADER_SEARCH_FIELDS)
        {
            immutable hdrOrEmpty = hdrKey in email.headers
                                              ? strip(email.headers[hdrKey].rawValue)
                                              : "";
            headerIndexText.put(hdrKey ~ ":" ~ hdrOrEmpty ~ "\n");
        }

        immutable opData = ["text": headerIndexText.data ~ "\n\n" ~ maybeText,
                            "emailDbId": email.id,
                            "userId": email.userId,
                            "isoDate": email.isoDate];

        collection("emailIndexContents").update(
                ["emailDbId": email.id], opData, UpdateFlags.Upsert
        );
    }


    string messageIdToDbId(in string messageId)
    {
        const findSelector = parseJsonString(
                format(`{"message-id": %s}`, Json(messageId).toString)
        );

        immutable res = collection("email").findOne(
                findSelector, ["_id": 1], QueryFlags.None
        );
        if (!res.isNull)
            return bsonStr(res["_id"]);
        return "";
    }


    /** Get the references for an email from the one it is replying to. It will return
     * the references for the caller, including the previous email references and
     * the previous email msgid appended
     */
    string[] getReferencesFromPrevious(in string id)
    {
        string[] references;
        immutable res = findOneById("email", id, "headers", "message-id");
        if (!res.isNull)
        {
            string[] inheritedRefs;

            if (!res.headers.isNull && !res.headers.references.isNull)
                inheritedRefs = bsonStrArraySafe(res.headers.references[0].addresses);
            references = inheritedRefs ~ bsonStr(res["message-id"]);
        }
        return references;
    }


    /** store or update the email into the DB, returns the DB id */
    string store(Email email,
                 in Flag!"ForceInsertNew"   forceInsertNew   = No.ForceInsertNew,
                 in Flag!"StoreAttachMents" storeAttachMents = Yes.StoreAttachMents)
    in
    {
        assert(email.userId !is null);
        assert(email.userId.length);
    }
    body
    {
        if (email.userId is null || !email.userId.length)
            throw new Exception("Cant store email without assigning a user");

        immutable rawHeadersStr    = email.headersToJson();
        immutable textPartsJsonStr = email.textPartsToJson();

        if (forceInsertNew || !email.id.length)
            email.id = BsonObjectID.generate().toString;

        Appender!string emailInsertJson;
        emailInsertJson.put(`{"$set": {`);
        emailInsertJson.put(format(
              `"deleted": %s,` ~
              `"sendStatus": "%s",` ~
              `"sendRetries": %s,` ~
              `"draft": %s,` ~
              `"userId": "%s",` ~
              `"destinationAddress": %s,` ~
              `"forwardedTo": %s,` ~
              `"rawEmailPath": %s,` ~
              `"message-id": %s,`    ~
              `"isodate": %s,`      ~
              `"from": { "rawValue": %s, "addresses": %s },` ~
              `"receivers": %s,`   ~
              `"headers": %s, `    ~
              `"textParts": [ %s ], ` ~
              `"bodyPeek": %s, `,
                email.deleted,
                to!string(email.sendStatus),
                email.sendRetries,
                email.draft,
                email.userId,
                Json(email.destinationAddress).toString,
                email.forwardedTo,
                Json(email.rawEmailPath).toString,
                Json(email.messageId).toString,
                Json(email.isoDate).toString,
                Json(email.from.rawValue).toString,      email.from.addresses,
                email.receivers,
                rawHeadersStr,
                textPartsJsonStr,
                Json(email.bodyPeek).toString,
        ));

        if (forceInsertNew)
            emailInsertJson.put(format(`"_id": %s,`, Json(email.id).toString));

        if (storeAttachMents)
        {
            emailInsertJson.put(
                    format(`"attachments": [ %s ]`, email.attachments.toJson)
            );
        }

        emailInsertJson.put("}}");
        //writeln(emailInsertJson.data);

        const bsonData = parseJsonString(emailInsertJson.data);
        collection("email").update(["_id": email.id], bsonData, UpdateFlags.Upsert);

        // store the index document for Mongo's full text search engine
        if (getConfig().storeTextIndex)
            storeTextIndex(email);

        return email.id;
    }
}
} // end version(MongoDriver)
