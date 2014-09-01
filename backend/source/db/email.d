module db.email;

import arsd.characterencodings: decodeBase64Stubborn;
import arsd.htmltotext;
import common.utils;
import db.attachcontainer;
import db.config;
import db.conversation;
import db.driveremailinterface;
import db.user;
import retriever.incomingemail;
import std.algorithm: among, sort, uniq;
import std.datetime;
import std.file;
import std.path: baseName, buildPath, extension;
import std.regex;
import std.stdio: File, writeln;
import std.string;
import std.typecons;
import std.utf: count, toUTFindex;
import vibe.core.log;
import vibe.data.bson;
import vibe.utils.dictionarylist;
import webbackend.apiemail;
version(MongoDriver)
{
    import db.mongo.driveremailmongo;
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


struct SearchResult
{
    const Conversation conversation;
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
    bool deleted = false;
    bool draft = false;
}


private HeaderValue field2HeaderValue(string field)
{
    HeaderValue hv;
    hv.rawValue = field;
    foreach(ref c; match(field, EMAIL_REGEX))
        if (c.hit.length) hv.addresses ~= c.hit;
    return hv;
}


final class Email
{
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
            dbDriver = new DriverEmailMongo();
        version(SqliteDriver)
            dbDriver = new DriverEmailSqlite();
        version(PostgreSQLDriver)
            dbDriver = new DriverEmailPostgres();
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


    private string jsonizeHeader(in string headerName,
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


    /** NOTE: * - dateStart and dateEnd should be GMT */
    static const(SearchResult)[] search(in string[] needles,
                                        in string userId,
                                        in string dateStart="",
                                        in string dateEnd="")
    {
        // Get an list of matching email IDs
        const matchingEmailAndConvIds = Email.dbDriver.searchEmails(needles, userId,
                                                                    dateStart, dateEnd);

        // keep the found conversations+matches indexes, the key is the conversation dbId
        SearchResult[string] map;

        // For every id, get the conversation (with MessageSummaries loaded)
        foreach(emailAndConvId; matchingEmailAndConvIds)
        {
            const conv = Conversation.get(emailAndConvId.convId);
            assert(conv !is null);

            uint indexMatching = -1;
            // find the index of the email inside the conversation
            foreach(int idx, const ref MessageLink link; conv.links)
            {
                if (link.emailDbId == emailAndConvId.emailId)
                {
                    indexMatching = idx;
                    break; // inner foreach
                }
            }
            assert(indexMatching != -1);

            if (conv.dbId in map)
                map[conv.dbId].matchingEmailsIdx ~= indexMatching;
            else
                map[conv.dbId] = SearchResult(conv, [indexMatching]);
        }
        return map.values;
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
        string[] allAddresses;
        string[] localAddresses;

        foreach(headerName; ["to", "cc", "bcc", "delivered-to"])
            allAddresses ~= getHeader(headerName).addresses;

        foreach(addr; allAddresses)
            if (User.addressIsLocal(addr))
                localAddresses ~= addr;

        return localAddresses;
    }


    // Proxies for the dbDriver functions used outside this class
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

    static void setDeleted(in string id,
                           in bool setDel,
                           in Flag!"UpdateConversation" update = Yes.UpdateConversation)
    {
        dbDriver.setDeleted(id, setDel, update);
    }

    static void removeById(in string id,
                           in Flag!"UpdateConversation" update = Yes.UpdateConversation)
    {
        dbDriver.removeById(id, update);
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
    import std.digest.md;
    import std.range;
    import db.test_support;

    unittest  // this(ApiEmail)
    {
        writeln("Testing Email.this(ApiEmail)");
        auto user = User.getFromAddress("anotherUser@testdatabase.com");
        auto apiEmail    = new ApiEmail;
        apiEmail.from    = "anotherUser@testdatabase.com";
        apiEmail.to      = "juanjux@gmail.com";
        apiEmail.subject = "draft subject 1";
        apiEmail.isoDate = "2014-08-20T15:47:06Z";
        apiEmail.date    = "Wed, 20 Aug 2014 15:47:06 +02:00";
        apiEmail.deleted = false;
        apiEmail.draft   = true;
        apiEmail.bodyHtml="<strong>I can do html like the cool boys!</strong>";

        // Test1: New draft, no reply
        auto dbEmail = new Email(apiEmail, "");
        dbEmail.userId = user.id;
        Email.dbDriver.store(dbEmail);
        assert(dbEmail.dbId.length);
        assert(dbEmail.messageId.endsWith("@testdatabase.com"));
        assert(!dbEmail.hasHeader("references"));
        assert(dbEmail.textParts.length == 1);

        // Test2: Update draft, no reply
        apiEmail.dbId = dbEmail.dbId;
        apiEmail.messageId = dbEmail.messageId;
        dbEmail = new Email(apiEmail, "");
        dbEmail.userId = user.id;
        Email.dbDriver.store(dbEmail);
        assert(dbEmail.dbId == apiEmail.dbId);
        assert(dbEmail.messageId == apiEmail.messageId);
        assert(!dbEmail.hasHeader("references"));
        assert(dbEmail.textParts.length == 1);

        // Test3: New draft, reply
        auto convs           = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        auto conv            = Conversation.get(convs[0].dbId);
        auto emailDbId       = conv.links[1].emailDbId;
        auto emailReferences = Email.get(emailDbId).getHeader("references").addresses;

        apiEmail.dbId      = "";
        apiEmail.messageId = "";
        apiEmail.bodyPlain = "I cant do html";

        dbEmail = new Email(apiEmail, emailDbId);
        dbEmail.userId = user.id;
        Email.dbDriver.store(dbEmail);
        assert(dbEmail.dbId.length);
        assert(dbEmail.messageId.endsWith("@testdatabase.com"));
        assert(dbEmail.getHeader("references").addresses.length ==
                emailReferences.length + 1);
        assert(dbEmail.textParts.length == 2);

        // Test4: Update draft, reply
        apiEmail.dbId = dbEmail.dbId;
        apiEmail.messageId = dbEmail.messageId;
        apiEmail.bodyHtml = "";
        dbEmail = new Email(apiEmail, emailDbId);
        dbEmail.userId = user.id;
        Email.dbDriver.store(dbEmail);
        assert(dbEmail.dbId == apiEmail.dbId);
        assert(dbEmail.messageId == apiEmail.messageId);
        assert(dbEmail.getHeader("references").addresses.length ==
                emailReferences.length + 1);
        assert(dbEmail.textParts.length == 1);
    }

    unittest // jsonizeHeader
    {
        writeln("Testing Email.jsonizeHeader");
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");

        auto inEmail = new IncomingEmail();
        auto testMailPath = buildPath(backendTestEmailsDir, "simple_alternative_noattach");
        inEmail.loadFromFile(testMailPath, getConfig.attachmentStore);
        auto emailDb = new Email(inEmail);

        assert(emailDb.jsonizeHeader("to") ==
                `"to": " Test User2 <testuser@testdatabase.com>",`);
        assert(emailDb.jsonizeHeader("Date", Yes.RemoveQuotes, Yes.OnlyValue) ==
                `" Sat, 25 Dec 2010 13:31:57 +0100",`);
    }


    unittest // test email.deleted
    {
        writeln("Testing Email.deleted");
        recreateTestDb();
        // insert a new email with deleted = true
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend",
                                                "test", "testemails");
        auto inEmail = scoped!IncomingEmail();
        auto mailname = "simple_alternative_noattach";
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                             getConfig.absAttachmentStore);
        auto dbEmail = new Email(inEmail);
        auto user = User.getFromAddress("anotherUser@testdatabase.com");
        dbEmail.userId = user.id;
        dbEmail.deleted = true;
        auto id = Email.dbDriver.store(dbEmail);

        // check that the doc has the deleted
        auto dbEmail2 = Email.get(id);
        assert(dbEmail2 !is null);
        assert(dbEmail2.deleted);

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

    unittest // search
    {
        // Not the same as the searchEmails test because "search" returns conversations
        // with several messages grouped (thus, less results sometimes)
        writeln("Testing Email.search");
        recreateTestDb();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        auto searchResults = Email.search(["inicio de sesión"], user1.id);
        assert(searchResults.length == 1);
        assert(searchResults[0].matchingEmailsIdx == [1]);

        auto searchResults2 = Email.search(["some"], user2.id);
        assert(searchResults2.length == 2);

        auto searchResults3 = Email.search(["some"], user2.id, "2014-06-01T14:32:20Z");
        assert(searchResults3.length == 1);
        auto searchResults4 = Email.search(["some"], user2.id, "2014-08-01T14:32:20Z");
        assert(searchResults4.length == 0);
        auto searchResults4b = Email.search(["some"], user2.id, "2018-05-28T14:32:20Z");
        assert(searchResults4b.length == 0);

        string startFixedDate = "2005-01-01T00:00:00Z";
        auto searchResults5 = Email.search(["some"], user2.id, startFixedDate,
                                           "2018-12-12T00:00:00Z");
        assert(searchResults5.length == 2);
        auto searchResults5b = Email.search(["some"], user2.id, startFixedDate,
                                            "2014-02-01T00:00:00Z");
        assert(searchResults5b.length == 1);
        assert(searchResults5b[0].matchingEmailsIdx.length == 1);
        auto searchResults5c = Email.search(["some"], user2.id, startFixedDate,
                                            "2015-02-21T00:00:00Z");
        assert(searchResults5c.length == 2);
    }


}

version(search_test)
{
    unittest  // search
    {
        writeln("Testing Email.search times");
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
        // last test on my laptop: about 40 msecs for 84 results with 33000 emails loaded
        StopWatch sw;
        sw.start();
        auto searchRes = Email.search(["testing"], user1.id);
        sw.stop();
        writeln(format("Time to search with a result set of %s convs: %s msecs",
                searchRes.length, sw.peek.msecs));
        sw.reset();
    }
}

