module db.email;

import arsd.htmltotext;
import common.utils;
import db.attachcontainer;
import db.config;
import retriever.incomingemail;
import std.algorithm: among;
import std.path: buildPath;
import std.regex;
import std.stdio: writeln;
import std.string;
import std.typecons;
import std.utf: count, toUTFindex;
import vibe.core.log;
import vibe.utils.dictionarylist;
import webbackend.apiemail;
version(MongoDriver)
{
    import db.mongo.mongo;
    import vibe.db.mongo.mongo;
}


struct TextPart
{
    string ctype;
    string content;

    this(string ctype, string content)
    {
        this.ctype=ctype;
        this.content=content;
    }
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

    string         dbId;
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

        immutable isNew   = (apiEmail.dbId.length == 0);
        immutable isReply = (repliedEmailDbId.length > 0);
        enforce(apiEmail.to.length,
                "Email from ApiEmail constructor should receive a .to");
        enforce(apiEmail.date.length,
                "Email from ApiEmail constructor should receive a .date");

        this.dbId      = isNew ? Email.dbDriver.generateNewId()
                               : apiEmail.dbId;
        this.messageId = isNew ? generateMessageId(domainFromAddress(apiEmail.from))
                               : apiEmail.messageId;

        if (isReply)
        {
            // get the references from the previous message
            auto references = Email.dbDriver.getReferencesFromPrevious(repliedEmailDbId);
            if (references.length == 0)
            {
                logWarn("Email.this(ApiEmail) ["~this.dbId~"] was suplied a " ~
                        "repliedEmailDbId but no email was found with that id: " ~
                        repliedEmailDbId);
            }
            else
            {
                auto referencesRaw = join(references, "\n        ");
                this.headers.addField("references", HeaderValue(referencesRaw, references));
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
     * dbId will be an empty string until .store() is called */
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
    package string maybeBodyNoFormat() const
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


    // ==========================================================
    // Proxies for the dbDriver functions used outside this class
    // ==========================================================
    string store(in Flag!"ForceInsertNew" forceNew = No.ForceInsertNew,
                 in Flag!"StoreAttachMents" storeAttachs = Yes.StoreAttachMents)
    {
        return dbDriver.store(this, forceNew, storeAttachs);
    }

    static Email get(in string dbId) { return dbDriver.get(dbId); }

    static EmailSummary getSummary(in string dbId) { return dbDriver.getSummary(dbId); }

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
