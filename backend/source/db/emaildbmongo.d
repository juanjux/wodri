module db.emaildbmongo;

version(MongoDriver)
{
import arsd.characterencodings: decodeBase64Stubborn;
import common.utils;
import db.attachcontainer: DbAttachment;
import db.config;
import db.conversation;
import db.email: Email, EmailSummary, TextPart;
import db.emaildbinterface;
import db.mongo;
import db.user;
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

final class EmailDbMongo : EmailDbInterface
{
    // non-interface helpers

    /** Paranoic retrieval of emailDoc headers */
    private static string headerRaw(const ref Bson emailDoc, in string headerName)
    {
        if (!emailDoc.headers.isNull &&
            !emailDoc.headers[headerName].isNull &&
            !emailDoc.headers[headerName][0].rawValue.isNull)
            return bsonStr(emailDoc.headers[headerName][0].rawValue);
        return "";
    }


    // Get an email document, return the attachment filenames in an array
    // XXX unittest
    private static string[] extractAttachNamesFromDoc(const ref Bson emailDoc)
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


    static auto getEmailCursorAtPosition(ulong pos)
    {
        auto cursor = collection("email").find();
        cursor.sort(["_id": 1]);
        assert(!cursor.empty);
        cursor.popFrontExactly(pos);
        return cursor;
    }


override: // interface methods

    Email get(in string dbId)
    {
        immutable emailDoc = findOneById("email", dbId);
        if (emailDoc.isNull || emailDoc.headers.isNull)
        {
            logWarn(format("Requested email with id %s is null or has null headers", dbId));
            return null;
        }

        auto ret               = new Email();
        ret.dbId               = dbId;
        ret.userId             = bsonStr(emailDoc["userId"]);
        ret.deleted            = bsonBool(emailDoc["deleted"]);
        ret.draft              = bsonBool(emailDoc["draft"]);
        ret.forwardedTo        = bsonStrArraySafe(emailDoc["forwardedTo"]);
        ret.destinationAddress = bsonStr(emailDoc["destinationAddress"]);
        ret.messageId          = bsonStr(emailDoc["message-id"]);
        ret.from               = HeaderValue(bsonStrSafe(emailDoc["from"].rawValue),
                                             bsonStrArraySafe(emailDoc["from"].addresses));
        ret.receivers          = HeaderValue(bsonStr(emailDoc["receivers"].rawValue),
                                             bsonStrArray(emailDoc["receivers"].addresses));
        ret.rawEmailPath       = bsonStrSafe(emailDoc["rawEmailPath"]);
        ret.bodyPeek           = bsonStrSafe(emailDoc["bodyPeek"]);
        ret.isoDate            = bsonStr(emailDoc["isodate"]);

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
                att.dbId      = bsonStr(attach.dbId);
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
    EmailSummary getSummary(in string dbId)
    in
    {
        assert(dbId.length);
    }
    body
    {
        auto res = new EmailSummary();
        immutable emailDoc = findOneById("email", dbId, "from", "headers", "isodate",
                                         "bodyPeek", "deleted", "draft", "attachments");

        if (!emailDoc.isNull)
        {
            res.dbId            = dbId;
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
        immutable userId = User.getIdFromLoginName(userName);
        if (!userId.length)
            return false;

        immutable emailDoc = collection("email").findOne(
                ["_id": emailId, "userId": userId], ["_id": 1], QueryFlags.None
        );
        return !emailDoc.isNull;
    }


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


    /** Adds an attachment to the email on the DB */
    string addAttachment(in string emailDbId,
                         in ApiAttachment apiAttach,
                         in string base64Content)
    {
        string attachId;

        if (apiAttach.dbId.length) // dont process attachs with a dbId set
        {
            logWarn("addAttachment was called with a non empty attachid."~
                    " emailId: " ~ emailDbId ~ " attachId: " ~ apiAttach.dbId);
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
        dbAttach.dbId      = attachId;
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
            if (bsonStrSafe(attachDoc.dbId) == attachmentId)
            {
                found = true;
                filePath = bsonStrSafe(attachDoc.realPath);
                break;
            }
        }

        if (!found)
        {
            logWarn(format("deleteAttachment: email [%s] doesnt have an attachment with " ~
                           "dbId [%s]", emailDbId, attachmentId));
            return;
        }

        immutable json = format(
                `{"$pull": {"attachments": {"dbId": %s}}}`, Json(attachmentId).toString
        );
        collection("email").update(["_id": emailDbId], parseJsonString(json));

        if (filePath.length && filePath.exists)
            remove(filePath);
    }


    /** Returns the raw email as string */
    string getOriginal(in string dbId)
    {
        immutable emailDoc = findOneById("email", dbId, "rawEmailPath");
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
    void setDeleted(in string dbId,
                    in bool setDel,
                    in Flag!"UpdateConversation" updateConv = Yes.UpdateConversation
    )
    {
        // Get the email from the DB, check the needed deleted and userId fields
        immutable emailDoc = findOneById("email", dbId, "deleted");
        if (emailDoc.isNull || emailDoc.deleted.isNull)
        {
            logWarn(format("setDeleted: Trying to set deleted (%s) of email with " ~
                           "id (%s) not in DB or with missing deleted field", setDel, dbId));
            return;
        }

        immutable dbDeleted = bsonBool(emailDoc.deleted);
        if (dbDeleted == setDel)
        {
            logWarn(format("setDeleted: Trying to set deleted to (%s) but email "
                           "with id (%s) already was in that state", setDel, dbId));
            return;
        }

        // Update the document
        immutable json = format(`{"$set": {"deleted": %s}}`, setDel);
        collection("email").update(["_id": dbId], parseJsonString(json));

        if (updateConv)
            Conversation.setEmailDeleted(dbId, setDel);
    }


    /**
     * Completely remove the email from the DB. If there is any conversation
     * with this emailId as is its only link it will be removed too. The attachments
     * and the rawEmail files will be removed too.
     */
    void removeById(
            in string dbId,
            in Flag!"UpdateConversation" updateConv = Yes.UpdateConversation
    )
    {
        immutable emailDoc = findOneById("email", dbId, "_id", "attachments", "rawEmailPath");
        if (emailDoc.isNull)
        {
            logWarn(format("Email.removeById: Trying to remove email with id (%s) " ~
                           " not in DB", dbId));
            return;
        }
        immutable emailId = bsonStr(emailDoc._id);

        if (updateConv)
        {
            auto convObject = Conversation.getByEmailId(emailId);
            if (convObject !is null)
            {
                // remove the link from the Conversation (which could trigger a
                // removal of the full conversation if it was the last locally stored link)
                convObject.removeLink(emailId);
                if (convObject.dbId.length > 0) // will be 0 if it was removed from the DB
                    convObject.store();
            }
            else
                logWarn(
                    format("Email.removeById: no conversation found for email (%s)",
                           dbId)
                );
        }

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
        assert(email.dbId.length);
    }
    body
    {
        if (!email.dbId.length)
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
                            "emailDbId": email.dbId,
                            "userId": email.userId,
                            "isoDate": email.isoDate];

        collection("emailIndexContents").update(
                ["emailDbId": email.dbId], opData, UpdateFlags.Upsert
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
    string[] getReferencesFromPrevious(in string dbId)
    {
        string[] references;
        immutable res = findOneById("email", dbId, "headers", "message-id");
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

        if (forceInsertNew || !email.dbId.length)
            email.dbId = BsonObjectID.generate().toString;

        Appender!string emailInsertJson;
        emailInsertJson.put(`{"$set": {`);
        emailInsertJson.put(format(
              `"deleted": %s,` ~
              `"draft": %s,` ~
              `"userId": "%s",` ~
              `"destinationAddress": %s,` ~
              `"forwardedTo": %s,` ~
              `"rawEmailPath": %s,` ~
              `"message-id": %s,`    ~
              `"isodate": %s,`      ~
              `"from": { "rawValue": %s, "addresses": %s },` ~
              `"receivers": { "rawValue": %s, "addresses": %s },`   ~
              `"headers": %s, `    ~
              `"textParts": [ %s ], ` ~
              `"bodyPeek": %s, `,
                email.deleted,
                email.draft,
                email.userId,
                Json(email.destinationAddress).toString,
                email.forwardedTo,
                Json(email.rawEmailPath).toString,
                Json(email.messageId).toString,
                Json(email.isoDate).toString,
                Json(email.from.rawValue).toString,      email.from.addresses,
                Json(email.receivers.rawValue).toString, email.receivers.addresses,
                rawHeadersStr,
                textPartsJsonStr,
                Json(email.bodyPeek).toString,
        ));

        if (forceInsertNew)
            emailInsertJson.put(format(`"_id": %s,`, Json(email.dbId).toString));

        if (storeAttachMents)
        {
            emailInsertJson.put(
                    format(`"attachments": [ %s ]`, email.attachments.toJson)
            );
        }

        emailInsertJson.put("}}");
        //writeln(emailInsertJson.data);

        const bsonData = parseJsonString(emailInsertJson.data);
        collection("email").update(["_id": email.dbId], bsonData, UpdateFlags.Upsert);

        // store the index document for Mongo's full text search engine
        if (getConfig().storeTextIndex)
            storeTextIndex(email);

        return email.dbId;
    }
}
} // end version(MongoDriver)


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|




version(db_test)
version(db_usetestdb)
{
    import db.test_support;
    import db.conversation;
    import std.digest.md;

    ApiEmail getTestApiEmail()
    {
        auto apiEmail = new ApiEmail();
        apiEmail.from      = "anotherUser@testdatabase.com";
        apiEmail.to        = "juanjo@juanjoalvarez.net";
        apiEmail.subject   = "test of forceInsertNew";
        apiEmail.isoDate   = "2014-08-22T09:22:46";
        apiEmail.date      = "Fri, 22 Aug 2014 09:22:46 +02:00";
        apiEmail.bodyPlain = "test body";
        return apiEmail;
    }


    unittest // EmailDbMongo.headerRaw
    {
        writeln("Testing EmailDbMongo.headerRaw");
        auto bson = parseJsonString("{}");
        auto emailDoc = collection("email").findOne(bson);

        assert(EmailDbMongo.headerRaw(emailDoc, "delivered-to") == " testuser@testdatabase.com");
        assert(EmailDbMongo.headerRaw(emailDoc, "date") == " Mon, 27 May 2013 07:42:30 +0200");
        assert(!EmailDbMongo.headerRaw(emailDoc, "inventedHere").length);
    }

    unittest // messageIdToDbId
    {
        writeln("Testing EmailDbMongo.messageIdToDbId");
        recreateTestDb();
        auto emailMongo = scoped!EmailDbMongo();
        auto id1 = emailMongo.messageIdToDbId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        auto id2 = emailMongo.messageIdToDbId("AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        auto id3 = emailMongo.messageIdToDbId("CAGA-+RScZe0tqmG4rbPTSrSCKT8BmkNAGBUOgvCOT5ywycZzZA@mail.gmail.com");
        auto id4 = emailMongo.messageIdToDbId("doesntexist");

        assert(id4 == "");
        assert((id1.length == id2.length) && (id3.length == id1.length) && id1.length == 24);
        auto arr = [id1, id2, id3, id4];
        assert(std.algorithm.count(arr, id1) == 1);
        assert(std.algorithm.count(arr, id2) == 1);
        assert(std.algorithm.count(arr, id3) == 1);
        assert(std.algorithm.count(arr, id4) == 1);
    }

    unittest // getSummary
    {
        writeln("Testing EmailDbMongo.getSummary");
        recreateTestDb();

        auto emailMongo = scoped!EmailDbMongo();
        auto convs    = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        auto conv     = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        auto summary = emailMongo.getSummary(conv.links[0].emailDbId);
        assert(summary.dbId == conv.links[0].emailDbId);
        assert(summary.from == " Some Random User <someuser@somedomain.com>");
        assert(summary.isoDate == "2014-01-21T14:32:20Z");
        assert(summary.date == " Tue, 21 Jan 2014 15:32:20 +0100");
        assert(summary.bodyPeek == "");
        assert(summary.avatarUrl == "");
        assert(summary.attachFileNames == ["C++ Pocket Reference.pdf"]);

        conv = Conversation.get(convs[0].dbId);
        assert(conv !is null);
        summary = emailMongo.getSummary(conv.links[0].emailDbId);
        assert(summary.dbId == conv.links[0].emailDbId);
        assert(summary.from == " SupremacyHosting.com Sales <brian@supremacyhosting.com>");
        assert(summary.isoDate.length);
        assert(summary.date == "");
        assert(summary.bodyPeek == "Well it is speculated that there are over 20,000 "~
                "hosting companies in this country alone. WIth that ");
        assert(summary.avatarUrl == "");
        assert(!summary.attachFileNames.length);
    }


    unittest // searchEmails
    {
        writeln("Testing EmailDbMongo.searchEmails");
        recreateTestDb();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        auto emailMongo = scoped!EmailDbMongo();
        auto results = emailMongo.searchEmails(["inicio de sesión"], user1.id);
        assert(results.length == 1);
        auto conv  = Conversation.get(results[0].convId);
        assert(conv.links[1].emailDbId == results[0].emailId);

        auto results2 = emailMongo.searchEmails(["some"], user1.id);
        assert(results2.length == 2);
        foreach(ref result; results2)
        {
            conv = Conversation.get(result.convId);
            bool found = false;
            foreach(ref link; conv.links)
            {
                if (link.emailDbId == result.emailId)
                {
                    found = true;
                    break;
                }
            }
            assert(found);
        }

        auto results3 = emailMongo.searchEmails(["some"], user2.id, "2014-06-01T14:32:20Z");
        assert(results3.length == 1);

        auto results4 = emailMongo.searchEmails(["some"], user2.id, "2014-06-01T14:32:20Z",
                                                 "2014-08-01T00:00:00Z");
        assert(results4.length == 1);

        string startFixedDate = "2005-01-01T00:00:00Z";
        auto results5 = emailMongo.searchEmails(["some"], user2.id, startFixedDate,
                                                 "2018-12-12T00:00:00Z");
        assert(results5.length == 2);

        auto results6 = emailMongo.searchEmails(["some"], user2.id, startFixedDate,
                                                 "2014-06-01T00:00:00Z");
        assert(results6.length == 1);
    }


    unittest // EmailDbMongo.getOriginal
    {
        writeln("Testing EmailDbMongo.getOriginal");
        recreateTestDb();

        auto emailMongo = scoped!EmailDbMongo();
        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        auto conv = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        auto rawText = emailMongo.getOriginal(conv.links[0].emailDbId);

        assert(toHexString(md5Of(rawText)) == "CFA0B90028C9E6C5130C5526ABB61F1F");
        assert(rawText.length == 1867294);
    }


    unittest // EmailDbMongo.addAttachment
    {
        writeln("Testing EmailDbMongo.addAttachment");
        recreateTestDb();

        // add
        auto emailDoc = EmailDbMongo.getEmailCursorAtPosition(0).front;
        auto emailDbId = bsonStr(emailDoc._id);

        ApiAttachment apiAttach;
        apiAttach.ctype = "text/plain";
        apiAttach.filename = "helloworld.txt";
        apiAttach.contentId = "someContentId";
        apiAttach.size = 12;
        string base64content = "aGVsbG8gd29ybGQ="; // "hello world"
        auto emailMongo = scoped!EmailDbMongo();
        auto attachId = emailMongo.addAttachment(emailDbId, apiAttach, base64content);

        emailDoc = EmailDbMongo.getEmailCursorAtPosition(0).front;
        assert(emailDoc.attachments.length == 3);
        auto attachDoc = emailDoc.attachments[2];
        assert(attachId == bsonStr(attachDoc.dbId));
        auto realPath = bsonStr(attachDoc.realPath);
        assert(realPath.exists);
        auto f = File(realPath, "r");
        ubyte[500] buffer;
        auto readBuf = f.rawRead(buffer);
        string fileContent = cast(string)readBuf.idup;
        assert(fileContent == "hello world");
    }


    unittest // EmailDbMongo.deleteAttachment
    {
        writeln("Testing EmailDbMongo.deleteAttachment");
        recreateTestDb();
        auto emailDoc = EmailDbMongo.getEmailCursorAtPosition(0).front;
        auto emailDbId = bsonStr(emailDoc._id);
        assert(emailDoc.attachments.length == 2);
        auto attachId = bsonStr(emailDoc.attachments[0].dbId);
        auto attachPath = bsonStr(emailDoc.attachments[0].realPath);
        auto dbMongo = scoped!EmailDbMongo();
        dbMongo.deleteAttachment(emailDbId, attachId);

        emailDoc = EmailDbMongo.getEmailCursorAtPosition(0).front;
        assert(emailDoc.attachments.length == 1);
        assert(bsonStr(emailDoc.attachments[0].dbId) != attachId);
        assert(!attachPath.exists);
    }

    unittest // setDeleted
    {
        writeln("Testing EmailDbMongo.setDeleted");
        recreateTestDb();

        auto emailMongo = scoped!EmailDbMongo();
        string messageId = "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com";
        auto dbId = emailMongo.messageIdToDbId(messageId);

        emailMongo.setDeleted(dbId, true);
        auto emailDoc = collection("email").findOne(["_id": dbId]);
        assert(bsonBool(emailDoc.deleted));
        auto conv = Conversation.getByReferences(bsonStr(emailDoc.userId),
                                                 [messageId], Yes.WithDeleted);
        assert(conv.links[1].deleted);

        emailMongo.setDeleted(dbId, false);
        emailDoc = collection("email").findOne(["_id": dbId]);
        assert(!bsonBool(emailDoc.deleted));
        conv = Conversation.getByReferences(bsonStr(emailDoc.userId),
                                            [messageId], Yes.WithDeleted);
        assert(!conv.links[1].deleted);
    }


    unittest // storeTextIndex
    {
        writeln("Testing EmailDbMongo.storeTextIndex");
        recreateTestDb();

        auto findJson = `{"$text": {"$search": "DOESNTEXISTS"}}`;
        auto cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(cursor.empty);

        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        findJson = `{"$text": {"$search": "text inside"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        assert(bsonStr(cursor.front.userId) == user1.id);
        string res = bsonStr(cursor.front.text);
        assert(countUntil(res, "text inside") == 157);

        findJson = `{"$text": {"$search": "email"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        assert(countUntil(toLower(bsonStr(cursor.front.text)), "email") != -1);
        cursor.popFront;
        assert(countUntil(toLower(bsonStr(cursor.front.text)), "email") != -1);
        cursor.popFront;
        assert(cursor.empty);

        findJson = `{"$text": {"$search": "inicio de sesión"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        assert(bsonStr(cursor.front.userId) == user1.id);
        res = bsonStr(cursor.front.text);
        auto foundPos = countUntil(res, "inicio de sesión");
        assert(foundPos != -1);

        findJson = `{"$text": {"$search": "inicio de sesion"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        res = bsonStr(cursor.front.text);
        auto foundPos2 = countUntil(res, "inicio de sesión");
        assert(foundPos == foundPos2);

        findJson = `{"$text": {"$search": "\"inicio de sesion\""}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(cursor.empty);
    }


    unittest
    {
        writeln("Testing EmailDbMongo.getReferencesFromPrevious");
        auto emailMongo = scoped!EmailDbMongo();
        assert(emailMongo.getReferencesFromPrevious("doesntexists").length == 0);

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        auto conv = Conversation.get(convs[0].dbId);

        auto refs = emailMongo.getReferencesFromPrevious(conv.links[1].emailDbId);
        assert(refs.length == 2);
        auto emailDoc = collection("email").findOne(["_id": conv.links[1].emailDbId]);
        assert(refs[$-1] == bsonStr(emailDoc["message-id"]));

        refs = emailMongo.getReferencesFromPrevious(conv.links[0].emailDbId);
        assert(refs.length == 1);
        emailDoc = collection("email").findOne(["_id": conv.links[0].emailDbId]);
        assert(refs[0] == bsonStr(emailDoc["message-id"]));
    }


    unittest // isOwnedBy
    {
        writeln("Testing EmailDbMongo.isOwnedBy");
        recreateTestDb();
        auto emailMongo = scoped!EmailDbMongo();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        assert(user1 !is null);
        assert(user2 !is null);

        auto cursor = EmailDbMongo.getEmailCursorAtPosition(0);
        auto email1 = cursor.front;
        assert(emailMongo.isOwnedBy(bsonStr(email1._id), user1.loginName));

        cursor.popFront();
        auto email2 = cursor.front;
        assert(emailMongo.isOwnedBy(bsonStr(email2._id), user1.loginName));

        cursor.popFront();
        auto email3 = cursor.front;
        assert(emailMongo.isOwnedBy(bsonStr(email3._id), user2.loginName));

        cursor.popFront();
        auto email4 = cursor.front;
        assert(emailMongo.isOwnedBy(bsonStr(email4._id), user2.loginName));

        cursor.popFront();
        auto email5 = cursor.front;
        assert(emailMongo.isOwnedBy(bsonStr(email5._id), user2.loginName));
    }

    unittest // removeById
    {
        struct EmailFiles
        {
            string rawEmail;
            string[] attachments;
        }

        // get the files on filesystem from the email (raw an attachments)
        EmailFiles getEmailFiles(string id)
        {
            auto doc = collection("email").findOne(["_id": id]);
            assert(!doc.isNull);

            auto res = EmailFiles(bsonStr(doc.rawEmailPath));

            foreach(ref attach; doc.attachments)
            {
                if (!attach.realPath.isNull)
                    res.attachments ~= bsonStr(attach.realPath);
            }
            return res;
        }

        void assertNoFiles(EmailFiles ef)
        {
            assert(!ef.rawEmail.exists);
            foreach(ref att; ef.attachments)
                assert(!att.exists);
        }

        writeln("Testing EmailDbMongo.removeById");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        auto singleMailConv = convs[0];
        auto singleConvId   = singleMailConv.dbId;
        auto singleMailId   = singleMailConv.links[0].emailDbId;
        auto emailMongo = scoped!EmailDbMongo();

        // since this is a single mail conversation, it should be deleted when the single
        // email is deleted
        auto emailFiles = getEmailFiles(singleMailId);
        emailMongo.removeById(singleMailId);
        auto emailDoc = collection("email").findOne(["_id": singleMailId]);
        assert(emailDoc.isNull);
        assertNoFiles(emailFiles);
        auto convDoc = collection("conversation").findOne(["_id": singleConvId]);
        assert(convDoc.isNull);

        // conversation with more links, but only one is actually in DB,
        // it should be removed too
        auto fakeMultiConv = convs[1];
        auto fakeMultiConvId = fakeMultiConv.dbId;
        auto fakeMultiConvEmailId = fakeMultiConv.links[2].emailDbId;
        emailFiles = getEmailFiles(fakeMultiConvEmailId);
        emailMongo.removeById(fakeMultiConvEmailId);
        emailDoc = collection("email").findOne(["_id": fakeMultiConvEmailId]);
        assert(emailDoc.isNull);
        assertNoFiles(emailFiles);
        convDoc = collection("conversation").findOne(["_id": fakeMultiConvId]);
        assert(convDoc.isNull);

        // conversation with more emails in the DB, the link of the email to
        // remove should be deleted but the conversation should be keept in DB
        auto multiConv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        auto multiConvId = multiConv.dbId;
        auto multiConvEmailId = multiConv.links[0].emailDbId;
        emailFiles = getEmailFiles(multiConvEmailId);
        emailMongo.removeById(multiConvEmailId);
        emailDoc = collection("email").findOne(["_id": multiConvEmailId]);
        assert(emailDoc.isNull);
        assertNoFiles(emailFiles);
        convDoc = collection("conversation").findOne(["_id": multiConvId]);
        assert(!convDoc.isNull);
        assert(!convDoc.links.isNull);
        assert(convDoc.links.length == 1);
        assert(!convDoc.links[0].emailId.isNull);
        assert(bsonStr(convDoc.links[0].emailId) != multiConvEmailId);
    }

    unittest // store()
    {
        writeln("Testing EmailDbMongo.store");
        recreateTestDb();
        // recreateTestDb already calls email.store, check that the inserted email is fine
        auto emailDoc = EmailDbMongo.getEmailCursorAtPosition(0).front;
        assert(emailDoc.headers.references[0].addresses.length == 1);
        assert(bsonStr(emailDoc.headers.references[0].addresses[0]) ==
                "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        assert(bsonStr(emailDoc.headers.subject[0].rawValue) ==
                " Fwd: Se ha evitado un inicio de sesión sospechoso");
        assert(emailDoc.attachments.length == 2);
        assert(bsonStr(emailDoc.attachments[0].dbId).length);
        assert(bsonStr(emailDoc.attachments[1].dbId).length);
        assert(bsonStr(emailDoc.isodate) == "2013-05-27T05:42:30Z");
        assert(bsonStr(emailDoc.receivers.addresses[0]) == "testuser@testdatabase.com");
        assert(bsonStr(emailDoc.from.addresses[0]) == "someuser@somedomain.com");
        assert(emailDoc.textParts.length == 2);
        assert(bsonStr(emailDoc.bodyPeek) == "Some text inside the email plain part");

        // check generated msgid
        auto cursor = EmailDbMongo.getEmailCursorAtPosition(
                countUntil(db.test_support.TEST_EMAILS, "spam_notagged_nomsgid")
        );
        assert(bsonStr(cursor.front["message-id"]).length);
        assert(bsonStr(cursor.front.bodyPeek) == "Well it is speculated that there are over 20,000 hosting companies in this country alone. WIth that ");
    }

    unittest
    {
        writeln("Testing EmailDbMongo.store(forceInsertNew)");
        recreateTestDb();
        auto emailMongo = scoped!EmailDbMongo();

        auto apiEmail = getTestApiEmail();
        auto dbEmail = new Email(apiEmail);
        dbEmail.userId = "xxx";
        auto dbIdFirst = emailMongo.store(dbEmail); // new
        apiEmail.dbId = dbIdFirst;
        dbEmail = new Email(apiEmail);
        dbEmail.userId = "xxx";
        auto dbIdSame = emailMongo.store(dbEmail); // no forceInserNew, should have the same id
        assert(dbIdFirst == dbIdSame);

        dbEmail = new Email(apiEmail);
        dbEmail.userId = "xxx";
        auto dbIdDifferent = emailMongo.store(dbEmail, Yes.ForceInsertNew);
        assert(dbIdDifferent != dbIdFirst);
    }

    unittest
    {
        writeln("Testing EmailDbMongo.store(storeAttachMents");
        recreateTestDb();
        auto emailMongo = scoped!EmailDbMongo();
        auto apiEmail = getTestApiEmail();
        apiEmail.attachments = [
            ApiAttachment(joinPath("/" ~ getConfig.URLAttachmentPath, "somefilecode.jpg"),
                          "testdbid", "ctype", "fname", "ctId", 1000)
        ];
        auto dbEmail = new Email(apiEmail);
        dbEmail.userId = "xxx";

        // should not store the attachments:
        auto dbId = emailMongo.store(dbEmail, No.ForceInsertNew, No.StoreAttachMents);
        auto emailDoc = collection("email").findOne(["_id": dbId]);
        assert(emailDoc.attachments.isNull);

        // should store the attachments
        emailMongo.store(dbEmail, No.ForceInsertNew, Yes.StoreAttachMents);
        emailDoc = collection("email").findOne(["_id": dbId]);
        assert(!emailDoc.attachments.isNull);
        assert(emailDoc.attachments.length == 1);
    }

    unittest // get
    {
        writeln("Testing EmailDbMongo.get");
        recreateTestDb();

        auto emailMongo = scoped!EmailDbMongo();
        auto emailDoc = EmailDbMongo.getEmailCursorAtPosition(0).front;
        auto emailId  = bsonStr(emailDoc._id);
        auto noEmail = emailMongo.get("noid");
        assert(noEmail is null);

        auto email    = emailMongo.get(emailId);
        assert(email.dbId.length);
        assert(!email.deleted);
        assert(!email.draft);
        assert(email.from == HeaderValue(" Some User <someuser@somedomain.com>",
                                         ["someuser@somedomain.com"]));
        assert(email.isoDate == "2013-05-27T05:42:30Z");
        assert(email.bodyPeek == "Some text inside the email plain part");
        assert(email.forwardedTo.length == 0);
        assert(email.destinationAddress == "testuser@testdatabase.com");
        assert(email.messageId == 
                "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(email.receivers == HeaderValue(" Test User1 <testuser@testdatabase.com>",
                                              ["testuser@testdatabase.com"]));
        assert(email.rawEmailPath.length);
        assert(email.attachments.length == 2);
        assert(email.attachments.list[0].ctype == "image/png");
        assert(email.attachments.list[0].filename == "google.png");
        assert(email.attachments.list[0].contentId == "<google>");
        assert(email.attachments.list[0].size == 6321L);
        assert(email.attachments.list[0].dbId.length);
        assert(email.attachments.list[1].ctype == "image/jpeg");
        assert(email.attachments.list[1].filename == "profilephoto.jpeg");
        assert(email.attachments.list[1].contentId == "<profilephoto>");
        assert(email.attachments.list[1].size == 1063L);
        assert(email.attachments.list[1].dbId.length);
        assert(email.textParts.length == 2);
        assert(strip(email.textParts[0].content) == "Some text inside the email plain part");
        assert(email.textParts[0].ctype == "text/plain");
        assert(email.textParts[1].ctype == "text/html");
    }
}
