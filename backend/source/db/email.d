module db.email;

import arsd.htmltotext;
import db.config;
import db.utils: removeDups;
import db.conversation;
import db.mongo;
import db.user;
import retriever.incomingemail: IncomingEmail, Attachment, HeaderValue;
import std.algorithm: among, sort, uniq;
import std.datetime;
import std.file: exists;
import std.path: baseName;
import std.stdio: File, writeln;
import std.string;
import std.typecons;
import std.utf: count, toUTFindex;
import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import vibe.inet.path: joinPath;
import vibe.utils.dictionarylist;
import webbackend.apiemail;

static shared immutable SEARCH_FIELDS = ["to", "subject", "cc", "bcc"];

final class TextPart
{
    string ctype;
    string content;

    this(string ctype, string content)
    {
        this.ctype   = ctype;
        this.content = content;
    }
}

private struct EmailAndConvIds
{
    string emailId;
    string convId;
}

struct SearchResult
{
    Conversation conversation;
    ulong[] matchingEmailsIdx;
}


final class EmailSummary
{
    string dbId;
    string from;
    string isoDate;
    string date;
    string[] attachFileNames;
    string bodyPeek;
    string avatarUrl;
    bool deleted=false;
}

/** Paranoic retrieval of emailDoc headers */
private string headerRaw(Bson emailDoc, string headerName)
{
    if (!emailDoc.headers.isNull &&
            !emailDoc.headers[headerName].isNull &&
            !emailDoc.headers[headerName][0].rawValue.isNull)
        return bsonStr(emailDoc.headers[headerName][0].rawValue);
    return "";
}

final class Email
{
    string       dbId;
    string       userId;
    bool         deleted = false;
    string[]     forwardedTo;
    string       destinationAddress;
    string       messageId;
    HeaderValue  from;
    HeaderValue  receivers;
    Attachment[] attachments;
    string       rawEmailPath;
    string       bodyPeek;
    string       isoDate;
    TextPart[]   textParts;
    DictionaryList!(HeaderValue, false) headers;

    this() {}

    /** Load from an IncomingEmail object (making mutable copies of the data members).
     * dbId will be an empty string until .store() is called */
    this(IncomingEmail email)
    {
        this.messageId    = email.getHeader("message-id").addresses[0];
        auto frHeader     = email.getHeader("from");
        this.from         = HeaderValue(frHeader.rawValue, frHeader.addresses.dup);
        this.rawEmailPath = email.rawEmailPath;
        this.isoDate      = BsonDate(
                                SysTime(email.date, TimeZone.getTimeZone("GMT"))
                            ).toString;

        foreach(headerName, const ref headerItem; email.headers)
        {
            auto hdr = HeaderValue(headerItem.rawValue, headerItem.addresses.dup);
            this.headers.addField(headerName, hdr);
        }

        foreach(const part; email.textualParts)
            this.textParts ~= new TextPart(part.ctype.name, part.textContent);

        foreach(attach; email.attachments)
        {
            auto att = Attachment(attach.realPath,
                                   attach.ctype,
                                   attach.filename,
                                   attach.contentId,
                                   attach.size);

            this.attachments ~= att;
        }

        extractBodyPeek();
        loadReceivers();

        this();
    }

    this(IncomingEmail email, string destination)
    {
        this(email);
        setOwner(destination);
    }

    void setOwner(string destinationAddress)
    {
        const user = User.getFromAddress(destinationAddress);
        if (user is null)
            throw new Exception("Trying to set a not local destination address: "
                                 ~ destinationAddress);
        this.userId = user.id;
        this.destinationAddress = destinationAddress;
    }


    bool hasHeader(string name) const
    {
        return (name in this.headers) != null;
    }


    HeaderValue getHeader(string name)
    {
        return hasHeader(name)? this.headers[name]: HeaderValue("", []);
    }


    private void extractBodyPeek()
    {
        // this is needed because string index != letters index for any non-ascii string

        const relevantPlain = maybeBodyNoFormat();
        // numer of unicode characters in the string
        const numChars = std.utf.count(relevantPlain);
        // whatever is lower of the configured body peek length or the UTF string length
        const peekUntilUtfLen = min(numChars, getConfig().bodyPeekLength);
        // convert the index of the number of UTF chars in the string to an array index
        const peekUntilArrayLen = toUTFindex(relevantPlain, peekUntilUtfLen);
        // and get the substring until that index
        this.bodyPeek = peekUntilUtfLen? relevantPlain[0..peekUntilArrayLen]: "";
    }


    private void loadReceivers()
    {
        // Some emails doesnt have a "To:" header but a "Delivered-To:". Really!
        string realReceiverField, realReceiverRawValue, realReceiverAddresses;
        if (hasHeader("to"))
            realReceiverField = "to";
        else if (hasHeader("bcc"))
            realReceiverField = "bcc";
        else if (hasHeader("delivered-to"))
            realReceiverField = "delivered-to";
        else
        {
            auto err = "Email doesnt have any receiver field set (to, cc, bcc, etc)";
            logError(err);
            return;
        }

        this.receivers = getHeader(realReceiverField);
    }


    /** Try to guess the relevant part of the email body and return it as plain text
     */
    private string maybeBodyNoFormat()
    {
        if (!this.textParts.length)
            return "";

        auto partAppender = appender!string;

        if (this.textParts.length == 2 &&
                this.textParts[0].ctype != this.textParts[1].ctype        &&
                among(this.textParts[0].ctype, "text/plain", "text/html") &&
                among(this.textParts[1].ctype, "text/plain", "text/html"))
        {
            // one html and one plain part, almost certainly related, store the plain one
            partAppender.put(this.textParts[0].ctype == "text/plain"?
                    this.textParts[0].content:
                    this.textParts[1].content);
        }
        else
        {
            // append and store all parts
            foreach(part; this.textParts)
            {
                if (part.ctype == "text/html")
                    partAppender.put(htmlToText(part.content));
                else
                    partAppender.put(part.content);
            }
        }
        return strip(partAppender.data);
    }


    private string jsonizeHeader(string headerName,
                                 Flag!"RemoveQuotes" removeQuotes = No.RemoveQuotes,
                                 Flag!"OnlyValue" onlyValue       = No.OnlyValue)
    {
        string ret;
        const hdr = getHeader(headerName);
        if (hdr.rawValue.length)
        {
            const strHeader = removeQuotes? removechars(hdr.rawValue, "\""): hdr.rawValue;

            ret = onlyValue?
                format("%s,", Json(strHeader).toString()):
                format("\"%s\": %s,", headerName, Json(strHeader).toString());
        }
        if (onlyValue && !ret.length)
            ret = `"",`;
        return ret;
    }


    pure ulong size() const
    {
        return textualBodySize() + attachmentsSize();
    }
    pure ulong attachmentsSize() const
    {
        ulong totalSize;
        foreach(ref attachment; this.attachments)
            totalSize += attachment.size;
        return totalSize;
    }
    pure ulong textualBodySize() const
    {
        ulong totalSize;
        foreach(textualPart; this.textParts)
            totalSize += textualPart.content.length;
        return totalSize;
    }


    @property Flag!"IsValidEmail" isValid()
    {
        // From and Message-ID and at least one of to/cc/bcc/delivered-to
        if ((getHeader("to").addresses.length  ||
             getHeader("cc").addresses.length  ||
             getHeader("bcc").addresses.length ||
             getHeader("delivered-to").addresses.length))
            return Yes.IsValidEmail;
        return No.IsValidEmail;
    }

    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================

    static string messageIdToDbId(string messageId)
    {
        const findSelector = parseJsonString(format(`{"message-id": %s}`, Json(messageId).toString));
        const res = collection("email").findOne(findSelector, ["_id": 1], QueryFlags.None);
        if (!res.isNull)
            return bsonStr(res["_id"]);
        return "";
    }
    

    // Get an email document, return the attachment filenames in an array
    private static string[] extractAttachNamesFromDoc(const ref Bson emailDoc)
    {
        string[] res;
        if (!emailDoc.isNull)
        {
            foreach(ref attach; emailDoc.attachments)
            {
                if (!attach.fileName.isNull)
                    res ~= bsonStr(attach.fileName);
            }
        }
        return res;
    }


    /**
     * Smaller version of the standar email object
     */
    static EmailSummary getSummary(string dbId)
    {
        auto res = new EmailSummary();
        const fieldSelector = ["from"        : 1,
                               "headers"     : 1,
                               "isodate"     : 1,
                               "bodyPeek"    : 1,
                               "deleted"     : 1,
                               "attachments" : 1];

        const emailDoc = collection("email").findOne(["_id": dbId], fieldSelector,
                                                     QueryFlags.None);

        if (!emailDoc.isNull)
        {
            res.dbId            = dbId;
            res.date            = headerRaw(emailDoc, "date");
            res.from            = bsonStr(emailDoc.from.rawValue);
            res.isoDate         = bsonStr(emailDoc.isodate);
            res.bodyPeek        = bsonStr(emailDoc.bodyPeek);
            res.deleted         = bsonBool(emailDoc.deleted);
            res.attachFileNames = extractAttachNamesFromDoc(emailDoc);
        }
        return res;
    }


    static string[] getAttachFileNames(string dbId)
    {
        string[] res;
        const emailDoc = collection("email").findOne(["_id": dbId], ["attachments": 1],
                                                     QueryFlags.None);
        return extractAttachNamesFromDoc(emailDoc);
    }


    static ApiEmail getApiEmail(string dbId)
    {
        ApiEmail ret = null;
        const fieldSelector = ["from": 1,
             "headers": 1,
             "isodate": 1,
             "textParts": 1,
             "deleted": 1,
             "attachments": 1];

        const emailDoc = collection("email").findOne(
                ["_id": dbId], fieldSelector, QueryFlags.None
        );

        if (!emailDoc.isNull)
        {
            ret = new ApiEmail();
            ret.dbId = dbId;

            // Headers
            if (!emailDoc.headers.isNull)
            {
                ret.to      = headerRaw(emailDoc, "to");
                ret.cc      = headerRaw(emailDoc, "cc");
                ret.bcc     = headerRaw(emailDoc, "bcc");
                ret.date    = headerRaw(emailDoc, "date");
                ret.subject = headerRaw(emailDoc, "subject");
                ret.deleted = bsonBool(emailDoc.deleted);
            }

            if (!emailDoc.deleted.isNull)
                ret.deleted = bsonBool(emailDoc.deleted);

            if (!emailDoc.from.rawValue.isNull)
                ret.from = bsonStr(emailDoc.from.rawValue);

            if (!emailDoc.isodate.isNull)
                ret.isoDate = bsonStr(emailDoc.isodate);

            // Attachments
            foreach(ref attach; emailDoc.attachments)
            {
                ApiAttachment att;
                att.size = to!uint(bsonNumber(attach.size));
                att.ctype = bsonStr(attach.contentType);
                if (!attach.fileName.isNull)
                    att.filename = bsonStr(attach.fileName);
                if (!attach.contentId.isNull)
                    att.contentId = bsonStr(attach.contentId);
                if (!attach.realPath.isNull)
                    att.Url = joinPath("/",
                            joinPath(getConfig().URLAttachmentPath,
                                     baseName(bsonStr(attach.realPath))));
                ret.attachments ~= att;
            }

            // Append all parts of the same type
            if (!emailDoc.textParts.isNull)
            {
                Appender!string bodyPlain;
                Appender!string bodyHtml;
                foreach(ref tpart; emailDoc.textParts)
                {
                    if (!tpart.contentType.isNull)
                    {
                        auto docCType = bsonStr(tpart.contentType);
                        if (docCType == "text/html" && !tpart.content.isNull)
                            bodyHtml.put(bsonStr(tpart.content));
                        else
                            bodyPlain.put(bsonStr(tpart.content));
                    }
                }
                ret.bodyHtml  = bodyHtml.data;
                ret.bodyPlain = bodyPlain.data;
            }
        }
        return ret;
    }


    static string getOriginal(string dbId)
    {
        const noMail = "Error: could not get raw email";
        const emailDoc = collection("email").findOne(["_id": dbId],
                                                     ["rawEmailPath": 1],
                                                     QueryFlags.None);
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
        return noMail;
    }


    /**
     * Update the email DB record/document and set the deleted field to setDel
     */
    static void setDeleted(string dbId, bool setDel,
                           Flag!"UpdateConversation" = Yes.UpdateConversation)
    {
        // Get the email from the DB, check the needed deleted and userId fields
        const emailDoc = collection("email").findOne(["_id": dbId],
                                                     ["deleted": 1],
                                                     QueryFlags.None);
        if (emailDoc.isNull || emailDoc.deleted.isNull)
        {
            logWarn(format("setDeleted: Trying to set deleted (%s) of email with id (%s) " ~
                        "not in DB or with missing deleted field", setDel, dbId));
            return;
        }

        const dbDeleted = bsonBool(emailDoc.deleted);
        if (dbDeleted == setDel)
        {
            logWarn(format("setDeleted: Trying to set deleted to (%s) but email with id " ~
                        "(%s) already was in that state", setDel, dbId));
            return;
        }

        // Update the document
        const json    = format(`{"$set": {"deleted": %s}}`, setDel);
        const bsonUpd = parseJsonString(json);
        collection("email").update(["_id": dbId], bsonUpd);

        if (Yes.UpdateConversation)
            Conversation.setEmailDeleted(dbId, setDel);
    }


    /**
     * Completely remove the email from the DB. If there is any conversation
     * with this emailId as is its only link it will be removed too
     */
    static void removeById(string dbId, Flag!"UpdateConversation" = Yes.UpdateConversation)
    {
        const emailDoc = collection("email").findOne(["_id": dbId],
                                                     ["_id": 1],
                                                     QueryFlags.None);
        if (emailDoc.isNull)
        {
            logWarn(format("Email.removeById: Trying to remove email with id (%s) not in DB",
                           dbId));
            return;
        }
        const emailId = bsonStr(emailDoc._id);

        if (Yes.UpdateConversation)
        {
            // Get the email's Conversation
            const json = format(`{"links.emailId": {"$in": ["%s"]}}`, emailId);
            const convDoc = collection("conversation").findOne(parseJsonString(json),
                                                               ["_id": 1],
                                                               QueryFlags.None);
            if (!convDoc.isNull)
            {
                auto convObject = Conversation.get(bsonStr(convDoc._id));
                assert(convObject !is null);
                enforce(convObject !is null);

                // If this is the only email in the conversation stored on db, delete it
                auto numLinksInDb = 0;
                foreach(ref link; convObject.links)
                {
                    if (link.emailDbId.length)
                        numLinksInDb++;
                }

                if (numLinksInDb < 2)
                    convObject.remove();
                else
                {
                    // remove the link
                    convObject.removeLink(emailId);
                    convObject.store();
                }
            }
            else
                logWarn(format("Email.removeById: no conversation found for email (%s)", dbId));
        }

        // Remove the email from the DB
        collection("email").remove(["_id": emailId]);
    }


    const(string[]) localReceivers()
    {
        string[] allAddresses;
        string[] localAddresses;

        foreach(headerName; ["to", "cc", "bcc", "delivered-to"])
            allAddresses ~= getHeader(headerName).addresses;

        foreach(addr; allAddresses)
            if (User.addressIsLocal(addr))
                localAddresses ~= addr;

        return localAddresses;
    }


    /** store or update the email into the DB, returns the DB id */
    string store(Flag!"ForceInsertNew" = No.ForceInsertNew)
    {
        assert(this.userId !is null);
        assert(this.userId.length);
        if (this.userId is null || !this.userId.length)
            throw new Exception("Cant store email without assigning a user");
        Appender!string jsonAppender;

        // json for the text parts
        foreach(idx, part; this.textParts)
            jsonAppender.put("{\"contentType\": " ~ Json(part.ctype).toString ~ ","
                              "\"content\": "     ~ Json(part.content).toString ~ "},");
        string textPartsJsonStr = jsonAppender.data;
        jsonAppender.clear();

        // json for the attachments
        foreach(ref attach; this.attachments)
        {
            jsonAppender.put(`{"contentType": ` ~ Json(attach.ctype).toString     ~ `,` ~
                             ` "realPath": `    ~ Json(attach.realPath).toString  ~ `,` ~
                             ` "size": `        ~ Json(attach.size).toString      ~ `,`);
            if (attach.contentId.length)
                jsonAppender.put(` "contentId": ` ~ Json(attach.contentId).toString ~ `,`);
            if (attach.filename.length)
                jsonAppender.put(` "fileName": `  ~ Json(attach.filename).toString  ~ `,`);
            jsonAppender.put("},");
        }
        string attachmentsJsonStr = jsonAppender.data();
        jsonAppender.clear();

        // Json for the headers (see the schema.txt doc)
        bool[string] alreadyDone;
        jsonAppender.put("{");
        foreach(headerName, ref headerValue; this.headers)
        {
            // mongo doesnt allow $ or . on key names, any header with these chars
            // is unimportant and broken anyway
            if (countUntil(headerName, "$") != -1 ||
                countUntil(headerName, ".") != -1)
                    continue;
            if (among(toLower(headerName), "from", "message-id"))
                // these are keys outside doc.headers because they're indexed
                continue;

            // headers can have several values per key and thus be repeated
            // in the foreach iteration but we extract all the first time
            if (headerName in alreadyDone)
                continue;
            alreadyDone[headerName] = true;

            auto allValues = this.headers.getAll(headerName);
            jsonAppender.put(format(`"%s": [`, toLower(headerName)));
            foreach(ref hv; allValues)
            {
                jsonAppender.put(format(`{"rawValue": %s`, Json(hv.rawValue).toString));
                if (hv.addresses.length)
                    jsonAppender.put(format(`,"addresses": %s`, to!string(hv.addresses)));
                jsonAppender.put("},");
            }
            jsonAppender.put("],");
        }
        jsonAppender.put("}");
        string rawHeadersStr = jsonAppender.data();
        jsonAppender.clear();

        if (Yes.ForceInsertNew || !this.dbId.length)
            this.dbId = BsonObjectID.generate().toString;

        auto emailInsertJson = format(
              `{"_id": %s,` ~
              `"deleted": %s,` ~
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
              `"bodyPeek": %s, ` ~
              `"attachments": [ %s ] }`,
                Json(this.dbId).toString,
                this.deleted,
                this.userId,
                Json(this.destinationAddress).toString,
                this.forwardedTo,
                Json(this.rawEmailPath).toString,
                Json(this.messageId).toString,
                Json(this.isoDate).toString,
                Json(this.from.rawValue).toString,
                this.from.addresses,
                Json(this.receivers.rawValue).toString,
                this.receivers.addresses,
                rawHeadersStr,
                textPartsJsonStr,
                Json(this.bodyPeek).toString,
                attachmentsJsonStr
        );
        //writeln(emailInsertJson);

        auto bsonData = parseJsonString(emailInsertJson);
        collection("email").update(["_id": this.dbId], bsonData, UpdateFlags.Upsert);

        // store the index document for Mongo's full text search engine
        if (getConfig().storeTextIndex)
            storeTextIndex();

        return this.dbId;
    }


    private void storeTextIndex()
    {
        assert(this.dbId.length);
        if (!this.dbId.length)
        {
            logError("Email.storeTextIndex: trying to store an email index without email id");
            return;
        }

        // body
        auto maybeText = maybeBodyNoFormat();

        // searchable headers (currently, to, from, cc, bcc and subject)
        Appender!string headerIndexText;
        headerIndexText.put("from:"~strip(this.from.rawValue)~"\n");
        foreach(hdrKey; SEARCH_FIELDS)
        {
            string hdrOrEmpty = hdrKey in headers? strip(headers[hdrKey].rawValue): "";
            headerIndexText.put(hdrKey ~ ":" ~ hdrOrEmpty ~ "\n");
        }

        auto opData = ["text": headerIndexText.data ~ "\n\n" ~ maybeText,
                       "emailDbId": this.dbId,
                       "isoDate": this.isoDate];
        collection("emailIndexContents").update(["emailDbId": this.dbId],
                                                opData,
                                                UpdateFlags.Upsert);
    }


    private static EmailAndConvIds[] searchEmailsGetIds(const string[] needles,
                                               string dateStart = "",
                                               string dateEnd = "")
    {
        EmailAndConvIds[] res;
        foreach(needle; needles)
        {
            Appender!string findJson;
            findJson.put(format(`{"$text": {"$search": "\"%s\""}`, needle));

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

            auto bson = parseJsonString(findJson.data);
            auto emailIdsCursor = collection("emailIndexContents").find(
                    bson,
                    ["_id": 1, "emailDbId": 1, "convDbId": 1],
                    QueryFlags.None
            ).sort(["lastDate": -1]);

            foreach(item; emailIdsCursor)
            {
                res ~= EmailAndConvIds(bsonStr(item.emailDbId), bsonStr(item.convDbId));
            }
        }
        return removeDups(res);
    }


    /** NOTES: 
     * - dateStart and dateEnd should be GMT 
     * - it could return less SearchResult's than limit because SearchResults 
     *   are conversations and limit are emails (and if a conversation has more than
     *   one matching email less than limit will be returned). 
     *   For getting N results, call this routine several times until you have as many
     * */
    static SearchResult[] search(const string[] needles,
                                 string dateStart="",
                                 string dateEnd="")
    {
        // Get an list of matching email IDs
        import std.datetime; // XXX quitar
        StopWatch sw; sw.start;
        auto matchingEmailAndConvIds = searchEmailsGetIds(needles, dateStart, dateEnd);
        sw.stop; writeln("searchEmailGetIds: ", sw.peek.msecs); sw.reset;

        // keep the found conversations+matches indexes, the key is the conversation dbId
        SearchResult[string] map;

        // For every id, get the conversation (with MessageSummaries loaded)
        uint total = 0; // XXX
        uint counter = 0;
        foreach(emailAndConvId; matchingEmailAndConvIds)
        {
            auto emailId = emailAndConvId.emailId;
            sw.start;
            auto conv = Conversation.get(emailAndConvId.convId);
            sw.stop; 
            total += sw.peek.msecs;
            writeln("\t Conversation.getByEmailId: ", sw.peek.msecs); sw.reset;
            writeln("\t Total: ", total);
            counter++;
            if (conv is null)
            {
                logWarn(format("Conversation not found for email with id [%s]", emailId));
                continue;
            }

            uint indexMatching = -1;
            // find the index of the email inside the conversation
            foreach(int idx, const ref MessageLink link; conv.links)
            {
                if (link.emailDbId == emailId)
                {
                    indexMatching = idx;
                    break; // inner foreach
                }
            }
            if (indexMatching == -1)
            {
                logWarn(format("DB returned result for search [%s] but conversation [%s]",
                        needles, emailId) ~"doesnt have any matching email");
                continue;
            }

            if (conv.dbId in map)
                map[conv.dbId].matchingEmailsIdx ~= indexMatching;
            else
                map[conv.dbId] = SearchResult(conv, [indexMatching]);
        }
        writeln("Average by Conversation: ", total*1.0/counter*1.0);
        return map.values;
    }


    static void setConversationInEmailIndex(string emailId, string convId)
    {
        const json = format(`{"$set": {"convId": %s}}`, Json(convId).toString);
        const bson = parseJsonString(json);
        collection("emailIndexContents").update(["emailDbId": emailId], bson);
    }
}


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


version(db_test)
version(db_usetestdb)
{
    import std.path;
    import retriever.incomingemail;
    import db.test_support;
    import std.digest.md;

    unittest // jsonizeHeader
    {
        writeln("Testing Email.jsonizeHeader");
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");

        auto inEmail = new IncomingEmailImpl();
        auto testMailPath = buildPath(backendTestEmailsDir, "simple_alternative_noattach");
        inEmail.loadFromFile(testMailPath, getConfig.attachmentStore);
        auto emailDb = new Email(inEmail);

        assert(emailDb.jsonizeHeader("to")   ==
                `"to": " Test User2 <testuser@testdatabase.com>",`);
        assert(emailDb.jsonizeHeader("Date", Yes.RemoveQuotes, Yes.OnlyValue) ==
                `" Sat, 25 Dec 2010 13:31:57 +0100",`);
    }

    unittest // Email.messageIdToDbId
    {
        writeln("Testing Email.messageIdToDbId");
        recreateTestDb();
        auto id1 = Email.messageIdToDbId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        auto id2 = Email.messageIdToDbId("AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        auto id3 = Email.messageIdToDbId("CAGA-+RScZe0tqmG4rbPTSrSCKT8BmkNAGBUOgvCOT5ywycZzZA@mail.gmail.com");
        auto id4 = Email.messageIdToDbId("doesntexist");

        assert(id4 == "");
        assert((id1.length == id2.length) && (id3.length == id1.length) && id1.length == 24);
        auto arr = [id1, id2, id3, id4];
        assert(std.algorithm.count(arr, id1) == 1);
        assert(std.algorithm.count(arr, id2) == 1);
        assert(std.algorithm.count(arr, id3) == 1);
        assert(std.algorithm.count(arr, id4) == 1);
    }

    unittest // Email.setDeleted
    {
        writeln("Testing Email.setDeleted");
        recreateTestDb();
        string messageId = "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com";
        auto dbId = Email.messageIdToDbId(messageId);

        Email.setDeleted(dbId, true);
        auto emailDoc = collection("email").findOne(["_id": dbId]);
        assert(bsonBool(emailDoc.deleted));
        auto conv = Conversation.getByReferences(bsonStr(emailDoc.userId),
                                                 [messageId], Yes.WithDeleted);
        assert(conv.links[1].deleted);

        Email.setDeleted(dbId, false);
        emailDoc = collection("email").findOne(["_id": dbId]);
        assert(!bsonBool(emailDoc.deleted));
        conv = Conversation.getByReferences(bsonStr(emailDoc.userId),
                                            [messageId], Yes.WithDeleted);
        assert(!conv.links[1].deleted);
    }

    unittest // removeById
    {
        writeln("Testing Email.removeById");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", 0, 0);
        auto singleMailConv = convs[0];
        auto singleConvId = singleMailConv.dbId;
        auto singleMailId = singleMailConv.links[0].emailDbId;

        // since this is a single mail conversation, it should be deleted
        // when the single email is deleted
        Email.removeById(singleMailId);
        auto emailDoc = collection("email").findOne(["_id": singleMailId]);
        assert(emailDoc.isNull);
        auto convDoc = collection("conversation").findOne(["_id": singleConvId]);
        assert(convDoc.isNull);

        // conversation with more links, but only one is actually in DB,
        // it should be removed too
        auto fakeMultiConv = convs[1];
        auto fakeMultiConvId = fakeMultiConv.dbId;
        auto fakeMultiConvEmailId = fakeMultiConv.links[2].emailDbId;
        Email.removeById(fakeMultiConvEmailId);
        emailDoc = collection("email").findOne(["_id": fakeMultiConvEmailId]);
        assert(emailDoc.isNull);
        convDoc = collection("conversation").findOne(["_id": fakeMultiConvId]);
        assert(convDoc.isNull);

        // conversation with more emails in the DB, the link of the email to
        // remove should be deleted but the conversation should be keept in DB
        auto multiConv = convs[3];
        auto multiConvId = multiConv.dbId;
        auto multiConvEmailId = multiConv.links[0].emailDbId;
        Email.removeById(multiConvEmailId);
        emailDoc = collection("email").findOne(["_id": multiConvEmailId]);
        assert(emailDoc.isNull);
        convDoc = collection("conversation").findOne(["_id": multiConvId]);
        assert(!convDoc.isNull);
        assert(!convDoc.links.isNull);
        assert(convDoc.links.length == 1);
        assert(!convDoc.links[0].emailId.isNull);
        assert(bsonStr(convDoc.links[0].emailId) != multiConvEmailId);
    }

    unittest // getSummary
    {
        writeln("Testing Email.getSummary");
        recreateTestDb();

        auto convs    = Conversation.getByTag("inbox", 0, 0);
        auto conv     = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        auto summary = Email.getSummary(conv.links[0].emailDbId);
        assert(summary.dbId == conv.links[0].emailDbId);
        assert(summary.from == " Some Random User <someuser@somedomain.com>");
        assert(summary.isoDate == "2014-01-21T14:32:20Z");
        assert(summary.date == " Tue, 21 Jan 2014 15:32:20 +0100");
        assert(summary.bodyPeek == "");
        assert(summary.avatarUrl == "");
        assert(summary.attachFileNames == ["C++ Pocket Reference.pdf"]);

        conv = Conversation.get(convs[0].dbId);
        assert(conv !is null);
        summary = Email.getSummary(conv.links[0].emailDbId);
        assert(summary.dbId == conv.links[0].emailDbId);
        assert(summary.from == " SupremacyHosting.com Sales <brian@supremacyhosting.com>");
        assert(summary.isoDate.length);
        assert(summary.date == "");
        assert(summary.bodyPeek == "Well it is speculated that there are over 20,000 "~
                "hosting companies in this country alone. WIth that ");
        assert(summary.avatarUrl == "");
        assert(!summary.attachFileNames.length);
    }

    unittest // headerRaw
    {
        writeln("Testing Email.headerRaw");
        auto bson = parseJsonString("{}");
        auto emailDoc = collection("email").findOne(bson);

        assert(headerRaw(emailDoc, "delivered-to") == " testuser@testdatabase.com");
        assert(headerRaw(emailDoc, "date") == " Mon, 27 May 2013 07:42:30 +0200");
        assert(!headerRaw(emailDoc, "inventedHere").length);
    }

    unittest // getApiEmail
    {
        writeln("Testing Email.getApiEmail");
        recreateTestDb();

        auto convs    = Conversation.getByTag("inbox", 0, 0);
        auto conv     = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        auto apiEmail = Email.getApiEmail(conv.links[0].emailDbId);

        assert(apiEmail.dbId == conv.links[0].emailDbId);
        assert(apiEmail.from == " Some Random User <someuser@somedomain.com>");
        assert(apiEmail.to == " Test User1 <anotherUser@anotherdomain.com>");
        assert(apiEmail.cc == "");
        assert(apiEmail.bcc == "");
        assert(apiEmail.subject == " Attachment test");
        assert(apiEmail.isoDate == "2014-01-21T14:32:20Z");
        assert(apiEmail.date == " Tue, 21 Jan 2014 15:32:20 +0100");
        assert(apiEmail.attachments.length == 1);
        assert(apiEmail.attachments[0].ctype == "application/pdf");
        assert(apiEmail.attachments[0].filename == "C++ Pocket Reference.pdf");
        assert(apiEmail.attachments[0].size == 1363761);
        assert(toHexString(md5Of(apiEmail.bodyHtml)) == "15232B94D39F8EA5A902BB78100C50A7");
        assert(toHexString(md5Of(apiEmail.bodyPlain))== "CB492B7DF9B5C170D7C87527940EFF3B");
        assert(apiEmail.attachments[0].Url.startsWith("/attachment/"));
        assert(apiEmail.attachments[0].Url.endsWith(".pdf"));
    }

    unittest // Email.getOriginal
    {
        writeln("Testing Email.getOriginal");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", 0, 0);
        auto conv = Conversation.get(convs[2].dbId);
        assert(conv !is null);
        auto apiEmail = Email.getApiEmail(conv.links[0].emailDbId);
        auto rawText = Email.getOriginal(conv.links[0].emailDbId);

        assert(toHexString(md5Of(rawText)) == "CFA0B90028C9E6C5130C5526ABB61F1F");
        assert(rawText.length == 1867294);
    }


    unittest // email.store()
    {
        import std.range;

        writeln("Testing Email.store");
        recreateTestDb();
        // recreateTestDb already calls email.store, check that the inserted email is fine
        auto cursor = collection("email").find();
        cursor.sort(parseJsonString(`{"_id": 1}`));
        assert(!cursor.empty);
        auto emailDoc = cursor.front; // email 0
        assert(emailDoc.headers.references[0].addresses.length == 1);
        assert(bsonStr(emailDoc.headers.references[0].addresses[0]) ==
                "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        assert(bsonStr(emailDoc.headers.subject[0].rawValue) ==
                " Fwd: Se ha evitado un inicio de sesión sospechoso");
        assert(emailDoc.attachments.length == 2);
        assert(bsonStr(emailDoc.isodate) == "2013-05-27T05:42:30Z");
        assert(bsonStr(emailDoc.receivers.addresses[0]) == "testuser@testdatabase.com");
        assert(bsonStr(emailDoc.from.addresses[0]) == "someuser@somedomain.com");
        assert(emailDoc.textParts.length == 2);
        assert(bsonStr(emailDoc.bodyPeek) == "Some text inside the email plain part");

        // check generated msgid
        cursor.popFrontExactly(countUntil(db.test_support.TEST_EMAILS, "spam_notagged_nomsgid"));
        assert(bsonStr(cursor.front["message-id"]).length);
        assert(bsonStr(cursor.front.bodyPeek) == "Well it is speculated that there are over 20,000 hosting companies in this country alone. WIth that ");
    }

    unittest // test email.deleted
    {
        writeln("Testing Email.deleted");
        // insert a new email with deleted = true
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend",
                                                "test", "testemails");
        auto inEmail = new IncomingEmailImpl();
        auto mailname = "simple_alternative_noattach";
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                             getConfig.absAttachmentStore);
        auto dbEmail = new Email(inEmail);
        auto user = User.getFromAddress("testuser@testdatabase.com");
        dbEmail.userId = user.id;
        dbEmail.deleted = true;
        auto id = dbEmail.store();

        // check that the doc has the deleted
        auto emailDoc = collection("email").findOne(["_id": id]);
        assert(bsonBool(emailDoc.deleted));

        // check that the conversation has the link.deleted for this email set to true
        Conversation.upsert(dbEmail, ["inbox"], []);
        auto conv = Conversation.getByReferences(user.id, [dbEmail.messageId],
                                                 Yes.WithDeleted);
        assert(conv !is null);
        foreach(ref msglink; conv.links)
        {
            if (msglink.messageId == dbEmail.messageId)
            {
                assert(msglink.deleted);
                assert(msglink.emailDbId == id);
                break;
            }
        }
    }

    unittest // storeTextIndex
    {
        writeln("Testing Email.storeTextIndex");
        recreateTestDb();
        auto findJson = `{"$text": {"$search": "DOESNTEXISTS"}}`;
        auto cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(cursor.empty);

        findJson = `{"$text": {"$search": "text inside"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        string res = cursor.front.text.toString;
        assert(countUntil(res, "text inside") == 165);

        findJson = `{"$text": {"$search": "email"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        assert(countUntil(toLower(cursor.front.text.toString), "email") != -1);
        cursor.popFront;
        assert(countUntil(toLower(cursor.front.text.toString), "email") != -1);
        cursor.popFront;
        assert(cursor.empty);

        findJson = `{"$text": {"$search": "inicio de sesión"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        res = cursor.front.text.toString;
        auto foundPos = countUntil(res, "inicio de sesión");
        assert(foundPos != -1);

        findJson = `{"$text": {"$search": "inicio de sesion"}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        res = cursor.front.text.toString;
        auto foundPos2 = countUntil(res, "inicio de sesión");
        assert(foundPos == foundPos2);

        findJson = `{"$text": {"$search": "\"inicio de sesion\""}}`;
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(cursor.empty);
    }

    unittest // search
    {
        // FIXME: improve, check inside some search results
        writeln("Testing Email.search");
        auto searchResults = Email.search(["inicio de sesión"], 20, 0);
        assert(searchResults.length == 1);
        assert(searchResults[0].matchingEmailsIdx == [1]);

        searchResults = Email.search(["some"], 20, 0);
        assert(searchResults.length == 3);

        searchResults = Email.search(["some"], 20, 0, "2010-01-21T14:32:20Z");
        assert(searchResults.length == 3);
        searchResults = Email.search(["some"], 20, 0, "2013-05-28T14:32:20Z");
        assert(searchResults.length == 2);
        searchResults = Email.search(["some"], 20, 0, "2018-05-28T14:32:20Z");
        assert(searchResults.length == 0);

        string startFixedDate = "2005-01-01T00:00:00Z";
        searchResults = Email.search(["some"], 20, 0, startFixedDate, "2018-12-12T00:00:00Z");
        assert(searchResults.length == 3);
        searchResults = Email.search(["some"], 20, 0, startFixedDate, "2013-05-28T00:00:00Z");
        assert(searchResults.length == 1);
        assert(searchResults[0].matchingEmailsIdx.length == 2);
        searchResults = Email.search(["some"], 20, 0, startFixedDate, "2014-02-21T00:00:00Z");
        assert(searchResults.length == 2);
    }

}

version(search_test)
{
    unittest  // search
    {
        writeln("Testing Email.search times");
        // last test on my laptop: about 277 msecs for 18 results with emailsummaries loaded
        StopWatch sw;
        sw.start();
        auto searchRes = Email.search(["testing"]);
        sw.stop();
        writeln(format("Time to search with a result set of %s convs: %s msecs", 
                searchRes.length, sw.peek.msecs));
        sw.reset();
    }
}

