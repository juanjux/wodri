module db.email;

import std.datetime: SysTime, TimeZone;
import std.utf: count, toUTFindex;
import std.algorithm: among;
import std.string;
import std.typecons;
import std.stdio: File, writeln;
import std.file: exists;
import std.path: baseName;

import vibe.data.bson;
import vibe.core.log;
import vibe.utils.dictionarylist;
import vibe.db.mongo.mongo;
import vibe.inet.path: joinPath;

import arsd.htmltotext;
import retriever.incomingemail: IncomingEmail, Attachment, HeaderValue;
import db.mongo;
import db.config;
import db.user;
import webbackend.apiemail;

class TextPart
{
    string ctype;
    string content;

    this(string ctype, string content)
    {
        this.ctype   = ctype;
        this.content = content;
    }
}

class EmailSummary
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
    }

    this(IncomingEmail email, string destination)
    {
        this(email);
        setOwner(destination);
    }


    void setOwner(string destinationAddress)
    {
        auto user = User.getFromAddress(destinationAddress);
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
        auto relevantPlain = maybeBodyNoFormat();
        // this is needed because string index != letters index for any non-ascii string
        auto numChars     = std.utf.count(relevantPlain);
        auto peekUntil    = min(numChars, getConfig().bodyPeekLength);
        auto peekUntilUtf = toUTFindex(relevantPlain, peekUntil);
        this.bodyPeek     = peekUntil? relevantPlain[0..peekUntilUtf]: "";
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
        auto hdr = getHeader(headerName);
        if (hdr.rawValue.length)
        {
            auto strHeader = removeQuotes? removechars(hdr.rawValue, "\""): hdr.rawValue;

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
        auto findSelector = parseJsonString(format(`{"message-id": "%s"}`, messageId));
        const res = collection("email").findOne(findSelector, ["_id": 1],
                QueryFlags.None);
        if (!res.isNull)
            return bsonStr(res["_id"]);
        return "";
    }


    static EmailSummary getSummary(string dbId)
    {
        auto res = new EmailSummary();
        auto fieldSelector = ["from": 1,
             "headers": 1,
             "isodate": 1,
             "bodyPeek": 1,
             "attachments": 1];

        const emailDoc = collection("email").findOne(["_id": dbId],
                fieldSelector,
                QueryFlags.None);
        if (!emailDoc.isNull)
        {
            res.dbId = dbId;
            res.date = headerRaw(emailDoc, "date");

            if (!emailDoc.from.rawValue.isNull)
                res.from = bsonStr(emailDoc.from.rawValue);

            if (!emailDoc.isodate.isNull)
                res.isoDate = bsonStr(emailDoc.isodate);

            if (!emailDoc.bodyPeek.isNull)
                res.bodyPeek = bsonStr(emailDoc.bodyPeek);

            if (!emailDoc.deleted.isNull)
                res.deleted = bsonBool(emailDoc.deleted);

            foreach(ref attach; emailDoc.attachments)
                if (!attach.fileName.isNull)
                    res.attachFileNames ~= bsonStr(attach.fileName);
        }
        return res;
    }


    static ApiEmail getApiEmail(string dbId)
    {
        ApiEmail ret;
        auto fieldSelector = ["from": 1,
             "headers": 1,
             "isodate": 1,
             "textParts": 1,
             "attachments": 1];

        auto emailDoc = collection("email").findOne(
                ["_id": dbId], fieldSelector, QueryFlags.None
        );

        if (!emailDoc.isNull)
        {
            ret.dbId = dbId;

            // Headers
            if (!emailDoc.headers.isNull)
            {
                ret.to      = headerRaw(emailDoc, "to");
                ret.cc      = headerRaw(emailDoc, "cc");
                ret.bcc     = headerRaw(emailDoc, "bcc");
                ret.date    = headerRaw(emailDoc, "date");
                ret.subject = headerRaw(emailDoc, "subject");
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
        string noMail = "Error: could not get raw email";
        const emailDoc = collection("email").findOne(["_id": dbId],
                ["rawEmailPath": 1],
                QueryFlags.None);
        if (!emailDoc.isNull && !emailDoc.rawEmailPath.isNull)
        {
            auto rawPath = bsonStr(emailDoc.rawEmailPath);
            if (rawPath.length && rawPath.exists)
            {
                Appender!string app;
                auto rawFile = File(rawPath, "r");
                while(!rawFile.eof) app.put(rawFile.readln());
                return app.data;
            }
        }
        return noMail;
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


    /** store or update the email into the DB */
    string store(Flag!"ForceInsertNew" = No.ForceInsertNew)
    {
        assert(this.userId !is null);
        assert(this.userId.length);
        if (this.userId is null || !this.userId.length)
            throw new Exception("Cant store email without assigning a user");
        Appender!string jsonAppender;

        // json for the text parts
        foreach(idx, part; this.textParts)
            jsonAppender.put("{\"contentType\": " ~ Json(part.ctype).toString() ~ ","
                              "\"content\": "     ~ Json(part.content).toString() ~ "},");
        string textPartsJsonStr = jsonAppender.data;
        jsonAppender.clear();

        // json for the attachments
        foreach(ref attach; this.attachments)
        {
            jsonAppender.put(`{"contentType": ` ~ Json(attach.ctype).toString()     ~ `,` ~
                             ` "realPath": `    ~ Json(attach.realPath).toString()  ~ `,` ~
                             ` "size": `        ~ Json(attach.size).toString()      ~ `,`);
            if (attach.contentId.length)
                jsonAppender.put(` "contentId": ` ~ Json(attach.contentId).toString() ~ `,`);
            if (attach.filename.length)
                jsonAppender.put(` "fileName": `  ~ Json(attach.filename).toString()  ~ `,`);
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
                // these are outside doc.headers because they're indexed
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
              `{"_id": "%s",` ~
              `"userId": "%s",` ~
              `"destinationAddress": "%s",` ~
              `"forwardedTo": %s,` ~
              `"rawEmailPath": "%s",` ~
              `"message-id": "%s",`    ~
              `"isodate": "%s",`      ~
              `"from": { "rawValue": %s, "addresses": %s },` ~
              `"receivers": { "rawValue": %s, "addresses": %s },`   ~
              `"headers": %s, `    ~
              `"textParts": [ %s ], ` ~
              `"bodyPeek": %s, ` ~
              `"attachments": [ %s ] }`,
                this.dbId,
                this.userId,
                this.destinationAddress,
                to!string(this.forwardedTo),
                this.rawEmailPath,
                this.messageId,
                this.isoDate,
                Json(this.from.rawValue).toString,
                to!string(this.from.addresses),
                Json(this.receivers.rawValue).toString,
                to!string(this.receivers.addresses),
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

        auto maybeText = maybeBodyNoFormat();
        if (!maybeText.length)
            return;

        auto opData = ["text": maybeText];
        collection("emailIndexContents").update(["emailDbId": this.dbId], 
                                                opData, 
                                                UpdateFlags.Upsert);
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

    unittest // jsonizeHeader
    {
        import db.email;

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

    unittest // getSummary
    {
        writeln("Testing Email.getSummary");
        recreateTestDb();
        import db.conversation;

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
        import db.conversation;
        import std.digest.md;

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
        import std.digest.md;
        import db.conversation;
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

    unittest // storeTextIndex
    {
        writeln("Testing Email.storeTextIndex");
        recreateTestDb();
        auto findJson = format(`{"$text": {"$search": "DOESNTEXISTS"}}`);
        auto cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(cursor.empty);

        findJson = format(`{"$text": {"$search": "text inside"}}`);
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        string res = cursor.front.text.toString;
        assert(countUntil(res, "text inside") == 6);

        findJson = format(`{"$text": {"$search": "email"}}`);
        cursor = collection("emailIndexContents").find(parseJsonString(findJson));
        assert(!cursor.empty);
        assert(countUntil(toLower(cursor.front.text.toString), "email") != -1);
        cursor.popFront;
        assert(countUntil(toLower(cursor.front.text.toString), "email") != -1);
        cursor.popFront;
        assert(cursor.empty);
    }
}
