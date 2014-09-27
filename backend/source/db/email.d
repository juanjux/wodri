module db.email;

import common.utils;
import db.attachcontainer;
import db.config;
import retriever.incomingemail;
import std.algorithm: among;
import std.base64;
import std.file;
import std.path: buildPath;
import std.regex;
import std.stdio: writeln, File;
import std.string;
import std.typecons;
import std.utf: count, toUTFindex;
import vibe.core.log;
import vibe.utils.dictionarylist;
import webbackend.apiemail;
import arsd.htmltotext;

version(MongoDriver)
{
    import db.mongo.mongo;
    import vibe.db.mongo.mongo;
}

enum TransferEncoding
{
    QuotedPrintable,
    Base64
}

struct TextPart
{
    string ctype;
    string content;

    this(string ctype, string content)
    {
        this.ctype  = ctype;
        this.content = content;
    }
}


final class EmailSummary
{
    string id;
    string from;
    string isoDate;
    string date;
    string[] attachFileNames;
    string bodyPeek;
    string avatarUrl;
    bool deleted = false;
    bool draft = false;
}


private HeaderValue field2HeaderValue(string field)
{
    HeaderValue hv;
    hv.rawValue = field;
    foreach(ref c; std.regex.match(field, EMAIL_REGEX))
        if (c.hit.length) hv.addresses ~= c.hit;
    return hv;
}


final class Email
{
    import db.dbinterface.driveremailinterface;
    private static DriverEmailInterface dbDriver = null;

    string         id;
    string         userId;
    bool           deleted = false;
    bool           draft = false;
    string[]       forwardedTo;
    string         destinationAddress;
    string         messageId;
    HeaderValue    from;
    HeaderValue    receivers;
    AttachContainer attachments;
    alias attachments this;
    string         rawEmailPath;
    string         bodyPeek;
    string         isoDate;
    TextPart[]     textParts;
    DictionaryList!(HeaderValue, false) headers;

    static this()
    {
        version(MongoDriver)
        {
            import db.mongo.driveremailmongo;
            dbDriver = new DriverEmailMongo();
        }
        enforce(dbDriver !is null, "You must select some DB driver!");
    }

    this()
    {
    }

    this(in ApiEmail apiEmail, in string repliedEmailDbId = "")
    {

        immutable isNew   = (apiEmail.id.length == 0);
        immutable isReply = (repliedEmailDbId.length > 0);
        enforce(apiEmail.to.length,
                "Email from ApiEmail constructor should receive a .to");
        enforce(apiEmail.date.length,
                "Email from ApiEmail constructor should receive a .date");
        this.id      = isNew ? Email.dbDriver.generateNewId()
                               : apiEmail.id;
        this.messageId = isNew ? generateMessageId(domainFromAddress(apiEmail.from))
                               : apiEmail.messageId;

        if (isReply)
        {
            // get the references from the previous message
            auto references = Email.dbDriver.getReferencesFromPrevious(repliedEmailDbId);
            if (references.length == 0)
            {
                logWarn("Email.this(ApiEmail) ["~this.id~"] was suplied a " ~
                        "repliedEmailDbId but no email was found with that id: " ~
                        repliedEmailDbId);
            }
            else
            {
                auto referencesRaw = join(references, "\r\n        ");
                this.headers.addField("references", HeaderValue(referencesRaw, references));
                this.headers.addField("in-reply-to", HeaderValue(references[$-1],
                                                                 references[$-1..$]));
            }
        }

        // Copy the other fields from the ApiEmail
        this.from    = field2HeaderValue(apiEmail.from);
        this.isoDate = apiEmail.isoDate;
        this.deleted = apiEmail.deleted;
        this.headers.addField("to",      field2HeaderValue(apiEmail.to));
        this.headers.addField("date",    HeaderValue(apiEmail.date));
        this.headers.addField("subject", HeaderValue(apiEmail.subject));
        this.headers.addField("cc",      field2HeaderValue(apiEmail.cc));
        this.headers.addField("bcc",     field2HeaderValue(apiEmail.bcc));

        if (apiEmail.bodyHtml.length)
            this.textParts ~= TextPart("text/html", apiEmail.bodyHtml);
        if (apiEmail.bodyPlain.length)
            this.textParts ~= TextPart("text/plain", apiEmail.bodyPlain);

        this.headers.addField("mime-type", HeaderValue("1.0"));
        this.headers.addField("sender", this.from);

        foreach(ref apiAttach; apiEmail.attachments)
        {
            this.attachments.add(apiAttach);
        }
        finishInitialization();
    }

    /** Load from an IncomingEmail object (making mutable copies of the data members).
     * id will be an empty string until .store() is called */
    this(in IncomingEmail inEmail)
    {
        const msgIdHdr = inEmail.getHeader("message-id");
        if (msgIdHdr.addresses.length)
            this.messageId  = msgIdHdr.addresses[0];
        else
            logWarn("Message didnt have any Message-id!");

        auto frHeader     = inEmail.getHeader("from");
        this.from         = HeaderValue(frHeader.rawValue, frHeader.addresses.dup);
        this.rawEmailPath = inEmail.rawEmailPath;
        this.isoDate      = BsonDate(
                                SysTime(inEmail.date, TimeZone.getTimeZone("GMT"))
                            ).toString;

        foreach(headerName, const ref headerItem; inEmail.headers)
        {
            auto hdr = HeaderValue(headerItem.rawValue, headerItem.addresses.dup);
            this.headers.addField(headerName, hdr);
        }

        foreach(const part; inEmail.textualParts)
            this.textParts ~= TextPart(part.ctype.name, part.textContent);

        foreach(attach; inEmail.attachments)
        {
            auto id = Email.dbDriver.generateNewId();
            this.attachments.add(attach, id);
            //this.attachments.add(attach, Email.dbDriver.generateNewId());
        }
        finishInitialization();
    }

    this(in IncomingEmail inEmail, in string destination)
    {
        this(inEmail);
        setOwner(destination);
    }


    void finishInitialization()
    {
        if (!this.bodyPeek.length)
            extractBodyPeek();
        if (!this.receivers.addresses.length)
            loadReceivers();
    }

    void setOwner(in string destinationAddress)
    {
        import db.user;
        const user = User.getFromAddress(destinationAddress);
        if (user is null)
            throw new Exception("Trying to set a not local destination address: "
                                 ~ destinationAddress);
        this.userId = user.id;
        this.destinationAddress = destinationAddress;
    }


    bool hasHeader(in string name) const
    {
        return (name in this.headers) !is null;
    }


    HeaderValue getHeader(in string name) const
    {
        // FIXME: remove when the bug related with the postblit
        // constructor in dmd 2.0.66 is fixed
        HeaderValue hv;
        if (this.hasHeader(name))
        {
            hv.rawValue  = this.headers[name].rawValue.idup;
            hv.addresses = this.headers[name].addresses.dup;
            return hv;
        }
        return hv;
    }


    private void extractBodyPeek()
    {
        // this is needed because string index != letters index for any non-ascii string
        immutable relevantPlain = maybeBodyNoFormat();
        // numer of unicode characters in the string
        immutable numChars = std.utf.count(relevantPlain);
        // whatever is lower of the configured body peek length or the UTF string length
        immutable peekUntilUtfLen = min(numChars, getConfig().bodyPeekLength);
        // convert the index of the number of UTF chars in the string to an array index
        immutable peekUntilArrayLen = toUTFindex(relevantPlain, peekUntilUtfLen);
        // and get the substring until that index
        this.bodyPeek = peekUntilUtfLen? relevantPlain[0..peekUntilArrayLen]: "";
    }


    private void loadReceivers()
    {
        // Some emails doesnt have a "To:" header but a "Delivered-To:". Really!
        string realReceiverField;
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
    package string maybeBodyNoFormat() const
    {
        if (!this.textParts.length)
            return "";

        auto partAppender = appender!string;

        TextPart[] ret = getAlternativePartsIfAlternative();
        if (ret !is null)
        {
            // one html and one plain part, almost certainly alternative, store the plain one
            partAppender.put(this.textParts[0].content);
        }
        else
        {
            // append and store all parts
            foreach(ref part; this.textParts)
            {
                if (part.ctype == "text/html")
                    partAppender.put(htmlToText(part.content));
                else
                    partAppender.put(part.content);
            }
        }
        return strip(partAppender.data);
    }


    package string jsonizeHeader(in string headerName,
                                 in Flag!"RemoveQuotes" removeQuotes = No.RemoveQuotes,
                                 in Flag!"OnlyValue" onlyValue       = No.OnlyValue)
    {
        string ret;
        const hdr = getHeader(headerName);
        if (hdr.rawValue.length)
        {
            const strHeader = removeQuotes ? removechars(hdr.rawValue, "\""): hdr.rawValue;
            ret = onlyValue ? format("%s,", Json(strHeader).toString())
                            : format("\"%s\": %s,", headerName, Json(strHeader).toString);
        }
        if (onlyValue && !ret.length)
            ret = `"",`;
        return ret;
    }


    ulong size() const
    nothrow
    {
        return textualBodySize() + this.attachments.totalSize();
    }


    ulong textualBodySize() const
    nothrow
    {
        ulong totalSize;
        foreach(textualPart; this.textParts)
            totalSize += textualPart.content.length;
        return totalSize;
    }


    @property Flag!"IsValidEmail" isValid() const
    {
        // From and Message-ID and at least one of to/cc/bcc/delivered-to
        if ((getHeader("to").addresses.length  ||
             getHeader("cc").addresses.length  ||
             getHeader("bcc").addresses.length ||
             getHeader("delivered-to").addresses.length))
            return Yes.IsValidEmail;
        return No.IsValidEmail;
    }


    version(MongoDriver)
    package string headersToJson() const
    {
        Appender!string jsonAppender;

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
            // with the call to getAll
            if (headerName in alreadyDone)
                continue;
            alreadyDone[headerName] = true;

            const allValues = this.headers.getAll(headerName);
            jsonAppender.put(format(`"%s": [`, toLower(headerName)));
            foreach(ref hv; allValues)
            {
                jsonAppender.put(format(`{"name": %s`, Json(headerName).toString));
                jsonAppender.put(format(`,"rawValue": %s`, Json(hv.rawValue).toString));
                if (hv.addresses.length)
                    jsonAppender.put(format(`,"addresses": %s`, to!string(hv.addresses)));
                jsonAppender.put("},");
            }
            jsonAppender.put("],");
        }
        jsonAppender.put("}");
        return jsonAppender.data;
    }


    version(MongoDriver)
    package string textPartsToJson() const
    {
        Appender!string jsonAppender;
        foreach(idx, part; this.textParts)
        {
            jsonAppender.put(`{"contentType": ` ~ Json(part.ctype).toString ~ "," ~
                              `"content": `     ~ Json(part.content).toString ~ "},");
        }
        return jsonAppender.data;
    }


    string[] localReceivers() const
    {
        import db.user;

        string[] allAddresses;
        string[] localAddresses;

        foreach(headerName; ["to", "cc", "bcc", "delivered-to"])
            allAddresses ~= getHeader(headerName).addresses;

        foreach(addr; allAddresses)
            if (User.addressIsLocal(addr))
                localAddresses ~= addr;

        return localAddresses;
    }


    string toRFCEmail(in string lineEnd = "\r\n")
    in
    {
        assert(this.from.rawValue.length);
        assert(lineEnd.length);
    }
    body
    {
        Appender!string emailAppender;
        bool isMixedOrRelated = void;
        string mainBoundary;
        TextPart[] alternativeParts = null;

        // Header
        emailAppender.put(generateRFCHeader(lineEnd, isMixedOrRelated, mainBoundary,
                                            alternativeParts));

        // Body
        if (isMixedOrRelated)
            emailAppender.put(lineEnd ~ "--" ~ mainBoundary ~ lineEnd);

        string lineEnd2 = lineEnd ~ lineEnd;
        if (alternativeParts != null)
        {
            string alternativeBoundary = void;

            if (isMixedOrRelated)
            {
                // multipart/alternative header
                alternativeBoundary = randomString(25);
                emailAppender.put(
                    format("Content-Type: multipart/alternative; boundary=%s%s",
                           alternativeBoundary, lineEnd)
                );
            }
            else // main content/type == multipart/alternative
                alternativeBoundary = mainBoundary;

            // text part: boundary + header + content
            auto beforeSpace = isMixedOrRelated ? lineEnd2 : lineEnd;
            emailAppender.put(beforeSpace ~ textPartHeader(alternativeParts[0].ctype,
                                                           alternativeBoundary, lineEnd));
            emailAppender.put(encodeQuotedPrintable(stripLeft(alternativeParts[0].content),
                                                              QuoteMode.Body, lineEnd));

            // html part: boundary + header + content
            emailAppender.put(lineEnd ~ textPartHeader(alternativeParts[1].ctype,
                                                        alternativeBoundary, lineEnd));
            emailAppender.put(encodeQuotedPrintable(stripLeft(alternativeParts[1].content),
                                                              QuoteMode.Body, lineEnd));

            // multipart/alternative ending
            emailAppender.put(lineEnd ~ "--" ~ alternativeBoundary ~ "--" ~ lineEnd);
        }
        else
        {
            foreach(ref part; this.textParts)
            {
                if (isMixedOrRelated) // multipart/mixed boundary and text part header
                    emailAppender.put(textPartHeader(part.ctype, mainBoundary, lineEnd));
                emailAppender.put(lineEnd ~ encodeQuotedPrintable(part.content, QuoteMode.Body,
                                                                  lineEnd));
            }
        }

        // Attachments
        foreach(ref attach; attachments.list)
        {
            assert(isMixedOrRelated);
            if (!attach.realPath.exists)
            {
                logWarn("Attachment to encode into outgoing email doesnt exists!: " ~
                        attach.realPath);
                continue;
            }

            emailAppender.put(lineEnd ~ attachmentPartHeader(attach, mainBoundary, lineEnd));
            auto f = File(attach.realPath, "r");
            foreach(encoded; Base64.encoder(f.byChunk(57)))
            {
                emailAppender.put(encoded ~ lineEnd);
            }
        }

        if (isMixedOrRelated) // multipart/mixed ending
            emailAppender.put(lineEnd2 ~ "--" ~ mainBoundary ~ "--" ~ lineEnd);

        if (!emailAppender.data.endsWith(lineEnd))
            emailAppender.put(lineEnd);

        return emailAppender.data;
    }


    private string generateRFCHeader(in string lineEnd,
                                     out bool isMixedOrRelated,
                                     out string mainBoundary,
                                     out TextPart[] alternativeParts)
    {
        isMixedOrRelated = false;

        if (!this.messageId.length)
            this.messageId = generateMessageId(domainFromAddress(this.from.rawValue));

        Appender!string headerApp;
        string ctype = getContentType(alternativeParts);
        string ctypeHeaderStr = "Content-Type: " ~ ctype;

        if (among(ctype, "multipart/mixed", "multipart/related"))
        {
            isMixedOrRelated = true;
            mainBoundary = randomString(25);
            ctypeHeaderStr ~= "; boundary=" ~ mainBoundary;
        }
        else if (ctype == "multipart/alternative")
        {
            mainBoundary = randomString(25);
            ctypeHeaderStr ~= "; boundary=" ~ mainBoundary;
        }
        else if (among(ctype, "text/plain", "text/html"))
        {
            ctypeHeaderStr ~= "; charset=UTF-8";
            headerApp.put("Content-Transfer-Encoding: quoted-printable" ~ lineEnd);
        }

        // get content type and boundary if mixed
        headerApp.put("Message-ID: " ~ this.messageId ~ lineEnd);
        headerApp.put("From: " ~ quoteHeaderAddressList(strip(this.from.rawValue)) ~ lineEnd);
        headerApp.put("MIME-Version: 1.0" ~ lineEnd);
        if (this.from.addresses.length)
            headerApp.put("Return-Path: <" ~ this.from.addresses[0] ~ ">" ~ lineEnd);
        else
            logWarn("No From address in the email when generating RFC output");
        headerApp.put(ctypeHeaderStr ~ lineEnd);

        // Rest of headers, iterate and quote the content if needed
        foreach(headerName, value; this.headers)
        {
            if (!value.rawValue.length)
                continue;

            string encodedValue;
            auto lowName = toLower(headerName);

            // skip these
            if (among(lowName, "content-type", "return-path", "mime-version",
                      "from", "message-id", "content-transfer-encoding"))
            {
                continue;
            }
            // encode these as address lists (encoded name / non encoded adress)
            else if (among(lowName, "from", "to", "cc", "bcc", "resent-from",
                           "resent-to", "resent-cc", "resent-bcc", "delivered-to",
                            "delivered-from"))
            {
                string stripValue = strip(value.rawValue);
                if (stripValue.length && !toLower(stripValue).startsWith("undisclosed-recipients"))
                    encodedValue = quoteHeaderAddressList(value.rawValue);
                else
                    encodedValue = value.rawValue;
            }
            // DONT encode these
            else if (among(lowName, "content-type", "received",
                           "received-spf", "message-id", "reply-to", "mime-version",
                           "resent-reply-to", "resent-message-id", "dkim-signature",
                           "authentication-results", "original-message-id", "encoding"))
            {
                encodedValue = strip(value.rawValue);
            }
            // encode all the content of these
            else
            {
                encodedValue = quoteHeader(strip(value.rawValue));
            }

            if (encodedValue.length)
            {
                headerApp.put(format("%s: %s%s",
                                     capitalizeHeader(headerName),
                                     encodedValue,
                                     lineEnd));
            }
        }

        return headerApp.data;
    }


    /**
       If parts are alternative (one text/html and one text/plain) return
       an array with [plain, html], else return null

       FIXME: use levenshteinDistance to determine if the plain and html parts
       are really alternative
    */
    private TextPart[] getAlternativePartsIfAlternative() const
    {
        // if two parts, one text/html and the other text/plain...
        if (this.textParts.length == 2 &&
            this.textParts[0].ctype != this.textParts[1].ctype &&
            among(this.textParts[0].ctype, "text/plain", "text/html") &&
            among(this.textParts[1].ctype, "text/plain", "text/html"))
        {
            // one html and one plain, probably alternative
            TextPart[] ret;
            // text plain first, html second
            if (this.textParts[0].ctype == "text/plain")
            {
                ret ~= this.textParts[0];
                ret ~= this.textParts[1];
            }
            else
            {
                ret ~= this.textParts[1];
                ret ~= this.textParts[0];
            }
            return ret;
        }
        return null;
    }


    /** Note: alternativeParts could be null if the parts are not alternative */
    private string getContentType(out TextPart[] alternativeParts)
    {
        string ctype = void;
        alternativeParts = getAlternativePartsIfAlternative();
        if (this.attachments.length)
            ctype = "multipart/mixed";
        else if (textParts.length == 1)
            ctype = textParts[0].ctype;
        else if (alternativeParts !is null)
            ctype = "multipart/alternative";
        else if (textParts.length > 1)
            ctype = "multipart/mixed";
        else
            ctype = "text/plain"; // fallback

        return ctype;
    }

    private string textPartHeader(
            in string ctype,
            in string boundary,
            in string lineEnd,
            in string charset = "UTF-8",
            in TransferEncoding tencoding = TransferEncoding.QuotedPrintable
    )
    {

        Appender!string partHeader;
        auto tencodingName = tencoding == TransferEncoding.QuotedPrintable ?
                                                        "quoted-printable" :
                                                        "base64";

        partHeader.put("--" ~ boundary ~ lineEnd);
        partHeader.put("Content-Type: " ~ ctype ~ "; charset=" ~ charset ~ lineEnd);
        partHeader.put("Content-Transfer-Encoding: " ~ tencodingName ~ lineEnd);
        partHeader.put(lineEnd);

        return partHeader.data;
    }


    private string attachmentPartHeader(
        const ref DbAttachment attach,
        in string boundary,
        in string lineEnd
    )
    {
        Appender!string attachHeader;

        string fname_enc = void;
        if (needsQuoting(attach.filename, QuoteMode.Detect))
            fname_enc = encodeQuotedPrintable(attach.filename, QuoteMode.Header, lineEnd);
        else
            fname_enc = attach.filename;

        attachHeader.put("--" ~ boundary ~ lineEnd);
        attachHeader.put("Content-Type: " ~ attach.ctype);
        if (attach.filename.length)
            attachHeader.put(";" ~ lineEnd ~ "\tname=\"" ~ fname_enc ~ "\"");
        attachHeader.put(lineEnd);

        attachHeader.put("Content-Disposition: attachment");
        if (attach.filename.length)
            attachHeader.put(";" ~ lineEnd ~ "\tfilename=\"" ~ fname_enc ~ "\"");
        attachHeader.put(lineEnd);

        attachHeader.put("Content-Transfer-Encoding: base64" ~ lineEnd);
        if (attach.contentId.length)
            attachHeader.put("Content-ID: " ~ attach.contentId ~ lineEnd);

        attachHeader.put(lineEnd);
        return attachHeader.data;
    }


    // ==========================================================
    // Proxies for the dbDriver functions used outside this class
    // ==========================================================
    string store(in Flag!"ForceInsertNew" forceNew = No.ForceInsertNew,
                 in Flag!"StoreAttachMents" storeAttachs = Yes.StoreAttachMents)
    {
        return dbDriver.store(this, forceNew, storeAttachs);
    }
    static Email get(in string id) { return dbDriver.get(id); }
    static EmailSummary getSummary(in string id) { return dbDriver.getSummary(id); }
    static string getOriginal(in string id) { return dbDriver.getOriginal(id); }
    static string messageIdToDbId(in string id) { return dbDriver.messageIdToDbId(id); }
    static bool isOwnedBy(in string emailId, in string userName)
    {
        return dbDriver.isOwnedBy(emailId, userName);
    }
    static string addAttachment(in string id, in ApiAttachment apiAttach, in string content)
    {
        return dbDriver.addAttachment(id, apiAttach, content);
    }
    static void deleteAttachment(in string id, in string attachId)
    {
        dbDriver.deleteAttachment(id, attachId);
    }
    // remember to update the conversation that owns this email when calling this,
    // or just call Conversation.setEmailDeleted
    static void setDeleted(in string id, in bool setDel)
    {
        dbDriver.setDeleted(id, setDel);
    }
    static void purgeById(in string id)
    {
        dbDriver.purgeById(id);
    }
}
