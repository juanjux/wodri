module retriever.db;

import std.stdio;
import std.typecons;
import std.string;
import std.datetime: SysTime, TimeZone;
import std.array;
import std.range;
import std.json;
import std.path;
import std.algorithm;
import std.file;
import std.regex;
import std.traits;

import vibe.db.mongo.mongo;
import vibe.core.log;
import vibe.data.json;

import arsd.htmltotext;
import retriever.userrule: Match, Action, UserFilter, SizeRuleType;
import retriever.incomingemail;
import retriever.envelope;
import retriever.conversation;
import webbackend.apiemail;


private MongoDatabase g_mongoDB;
private RetrieverConfig g_config;

alias bsonStr      = deserializeBson!string;
alias bsonId       = deserializeBson!BsonObjectID;
alias bsonBool     = deserializeBson!bool;
alias bsonStrArray = deserializeBson!(string[]);
alias bsonStrHash  = deserializeBson!(string[string]);


auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");

version(db_test) version = db_usetestdb;

/**
 * Read the /etc/dbconnect.json file, check for missing keys and connect
 */
static this()
{
    auto mandatoryKeys = ["host", "name",  "password", "port",
                               "testname", "type", "user"];
    sort(mandatoryKeys);

    auto dbData = parseJSON(readText("/etc/webmail/dbconnect.json"));
    auto sortedKeys = dbData.object.keys.dup;
    sort(sortedKeys);

    const keysDiff = setDifference(sortedKeys, mandatoryKeys).array;
    enforce(!keysDiff.length, "Mandatory keys missing on dbconnect.json config file: %s"
                              ~ to!string(keysDiff));
    enforce(dbData["type"].str == "mongodb", "Only MongoDB is currently supported");
    string connectStr = format("mongodb://%s:%s@%s:%s/%s?safe=true",
                               dbData["user"].str,
                               dbData["password"].str,
                               dbData["host"].str,
                               dbData["port"].integer,
                               "admin");

    version(db_usetestdb)
    {
        g_mongoDB = connectMongoDB(connectStr).getDatabase(dbData["testname"].str);
        insertTestSettings();
    }
    else
    {
        g_mongoDB = connectMongoDB(connectStr).getDatabase(dbData["name"].str);
    }
    g_config = getInitialConfig();
}


struct RetrieverConfig
{
    string mainDir;
    string rawEmailStore;
    string attachmentStore;
    ulong  incomingMessageLimit;
    bool   storeTextIndex;
    string smtpServer;
    uint   smtpEncription;
    ulong  smtpPort;
    string smtpUser;
    string smtpPass;
    uint   bodyPeekLength;
}


struct EmailSummary
{
    string dbId;
    string from;
    string isoDate;
    string date;
    string[] attachFileNames;
    string bodyPeek;
    string avatarUrl;
}


private double bsonNumber(const Bson input)
{
    switch(input.type)
    {
        case Bson.Type.double_:
            return deserializeBson!double(input);
        case Bson.Type.int_:
            return to!double(deserializeBson!int(input));
        case Bson.Type.long_:
            return to!double(deserializeBson!long(input));
        default:
            auto err = format("Bson input is not of numeric type but: ", input.type);
            logError(err);
            throw new Exception(err);
    }
    assert(0);
}


ref const(RetrieverConfig) getConfig()
{
    return g_config;
}


private const(RetrieverConfig) getInitialConfig()
{
    RetrieverConfig _config;
    immutable dbConfig = g_mongoDB["settings"].findOne(["module": "retriever"]);
    if (dbConfig.isNull)
    {
        auto err = "Could not retrieve config database, collection:settings,"~
                   " module=retriever";
        logError(err);
        throw new Exception(err);
    }

    void checkNotNull(string[] keys)
    {
        string[] missingKeys = [];
        foreach(key; keys)
            if (dbConfig[key].isNull)
                missingKeys ~= key;

        if (missingKeys.length)
        {
            auto err = "Missing keys in retriever DB config collection: " ~
                                 to!string(missingKeys);
            logError(err);
            throw new Exception(err);
        }
    }

    checkNotNull(["mainDir", "smtpServer", "smtpUser", "smtpPass",
                  "smtpEncription", "smtpPort", "rawEmailStore",
                  "attachmentStore", "incomingMessageLimit", "storeTextIndex",
                  "bodyPeekLength"]);

    _config.mainDir              = bsonStr(dbConfig.mainDir);
    _config.smtpServer           = bsonStr(dbConfig.smtpServer);
    _config.smtpUser             = bsonStr(dbConfig.smtpUser);
    _config.smtpPass             = bsonStr(dbConfig.smtpPass);
    _config.smtpEncription       = to!uint(bsonNumber(dbConfig.smtpEncription));
    _config.smtpPort             = to!ulong(bsonNumber(dbConfig.smtpPort));
    auto dbPath                  = bsonStr(dbConfig.rawEmailStore);
    // If the db path starts with '/' interpret it as absolute
    _config.rawEmailStore        = dbPath.startsWith(dirSeparator)?
                                                           dbPath:
                                                           buildPath(_config.mainDir,
                                                                     dbPath);
    auto attachPath              = bsonStr(dbConfig.attachmentStore);
    _config.attachmentStore      = attachPath.startsWith(dirSeparator)?
                                                               attachPath:
                                                               buildPath(_config.mainDir,
                                                                         attachPath);
    _config.incomingMessageLimit = to!ulong(bsonNumber(dbConfig.incomingMessageLimit));
    _config.storeTextIndex       = bsonBool(dbConfig.storeTextIndex);
    _config.bodyPeekLength       = to!uint(bsonNumber(dbConfig.bodyPeekLength));
    return _config;
}


Flag!"HasDefaultUser" domainHasDefaultUser(string domainName)
{
    auto domain = g_mongoDB["domain"].findOne(["name": domainName],
                                              ["defaultUser": 1],
                                              QueryFlags.None);
    if (!domain.isNull &&
        !domain.defaultUser.isNull &&
        bsonStr(domain.defaultUser).length)
        return Yes.HasDefaultUser;
    return No.HasDefaultUser;
}


const(UserFilter[]) getAddressFilters(string address)
{
    UserFilter[] res;
    auto userRuleFindJson = parseJsonString(
            format(`{"destinationAccounts": {"$in": ["%s"]}}`, address)
    );
    auto userRuleCursor   = g_mongoDB["userrule"].find(userRuleFindJson);

    foreach(ref rule; userRuleCursor)
    {
        Match match;
        Action action;
        try
        {
            auto sizeRule = bsonStr(rule.match_sizeRuleType);
            switch(sizeRule)
            {
                case "None":
                    match.totalSizeType = SizeRuleType.None; break;
                case "SmallerThan":
                    match.totalSizeType = SizeRuleType.SmallerThan; break;
                case "GreaterThan":
                    match.totalSizeType = SizeRuleType.GreaterThan; break;
                default:
                    auto err = "SizeRuleType must be one of None, GreaterThan or SmallerThan";
                    logError(err);
                    throw new Exception(err);
            }

            match.withAttachment = bsonBool      (rule.match_withAttachment);
            match.withHtml       = bsonBool      (rule.match_withHtml);
            match.totalSizeValue = to!ulong      (bsonNumber(rule.match_totalSizeValue));
            match.bodyMatches    = bsonStrArray  (rule.match_bodyText);
            match.headerMatches  = bsonStrHash   (rule.match_headers);

            action.noInbox       = bsonBool      (rule.action_noInbox);
            action.markAsRead    = bsonBool      (rule.action_markAsRead);
            action.deleteIt      = bsonBool      (rule.action_delete);
            action.neverSpam     = bsonBool      (rule.action_neverSpam);
            action.setSpam       = bsonBool      (rule.action_setSpam);
            action.forwardTo     = bsonStrArray  (rule.action_forwardTo);
            action.addTags       = bsonStrArray  (rule.action_addTags);

            res ~= new UserFilter(match, action);
        } catch (Exception e)
            logWarn("Error deserializing rule from DB, ignoring: %s: %s", rule, e);
    }
    return res;
}


bool addressIsLocal(string address)
{
    if (!address.length)
        return false;

    if (domainHasDefaultUser(address.split("@")[1]) == Yes.HasDefaultUser)
        return true;

    auto selector   = parseJsonString(`{"addresses": {"$in": ["` ~ address ~ `"]}}`);
    auto userRecord = g_mongoDB["user"].findOne(selector);
    return !userRecord.isNull;
}


const(string[]) localReceivers(const IncomingEmail email)
{
    string[] allAddresses;
    string[] localAddresses;

    foreach(headerName; ["to", "cc", "bcc", "delivered-to"])
        allAddresses ~= email.getHeader(headerName).addresses;

    foreach(addr; allAddresses)
        if (addressIsLocal(addr))
            localAddresses ~= addr;

    return localAddresses;
}


private string jsonizeHeader(const IncomingEmail email, string headerName,
                     Flag!"RemoveQuotes" removeQuotes = No.RemoveQuotes,
                     Flag!"OnlyValue" onlyValue       = No.OnlyValue)
{
    string ret;
    auto hdr = email.getHeader(headerName);
    if (hdr.rawValue.length)
    {
        string strHeader = hdr.rawValue;
        if (removeQuotes)
            strHeader = removechars(strHeader, "\"");

        if (onlyValue)
            ret = format("%s,", Json(strHeader).toString());
        else
            ret = format("\"%s\": %s,", headerName, Json(strHeader).toString());
    }
    if (onlyValue && !ret.length)
        ret = `"",`;
    return ret;
}


string getEmailIdByMessageId(string messageId)
{
    auto findSelector = parseJsonString(format(`{"message-id": "%s"}`, messageId));
    const res = g_mongoDB["email"].findOne(findSelector, ["_id": 1],
                                           QueryFlags.None);
    if (!res.isNull)
        return bsonStr(res["_id"]);
    return "";
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


EmailSummary getEmailSummary(string dbId)
{
    EmailSummary res;
    auto fieldSelector = ["from": 1,
                          "headers": 1,
                          "isodate": 1,
                          "bodyPeek": 1,
                          "attachments": 1];

    const emailDoc = g_mongoDB["email"].findOne(["_id": dbId],
                                                fieldSelector,
                                                QueryFlags.None);
    if (!emailDoc.isNull)
    {
        res.dbId = dbId;
        res.date = emailDoc.headerRaw("date");

        if (!emailDoc.from.rawValue.isNull)
            res.from = bsonStr(emailDoc.from.rawValue);

        if (!emailDoc.isodate.isNull)
            res.isoDate = bsonStr(emailDoc.isodate);

        if (!emailDoc.bodyPeek.isNull)
            res.bodyPeek = bsonStr(emailDoc.bodyPeek);

        foreach(ref attach; emailDoc.attachments)
            if (!attach.fileName.isNull)
                res.attachFileNames ~= bsonStr(attach.fileName);
    }
    return res;
}


// XXX unittest
ApiEmail getApiEmail(string dbId)
{
    ApiEmail ret;
    auto fieldSelector = ["from": 1,
                          "headers": 1,
                          "isodate": 1,
                          "textParts": 1,
                          "attachments": 1];

    const emailDoc = g_mongoDB["email"].findOne(["_id": dbId],
                                                fieldSelector,
                                                QueryFlags.None);
    if (!emailDoc.isNull)
    {
        ret.dbId = dbId;

        // Headers
        if (!emailDoc.headers.isNull)
        {
            ret.to      = emailDoc.headerRaw("to");
            ret.cc      = emailDoc.headerRaw("cc");
            ret.bcc     = emailDoc.headerRaw("bcc");
            ret.date    = emailDoc.headerRaw("date");
            ret.subject = emailDoc.headerRaw("subject");
        }

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


private Conversation conversationDocToObject(ref Bson convDoc)
{
    Conversation ret;
    if (!convDoc.isNull)
    {
        ret.dbId         = bsonStr(convDoc._id);
        ret.userDbId     = bsonStr(convDoc.userId);
        ret.lastDate     = bsonStr(convDoc.lastDate);
        ret.tags         = bsonStrArray(convDoc.tags);
        ret.cleanSubject = bsonStr(convDoc.cleanSubject);

        foreach(link; convDoc.links)
        {
            auto msgId = bsonStr(link["message-id"]);
            ret.addLink(msgId, bsonStr(link["emailId"]));
            auto emailSummary = getEmailSummary(getEmailIdByMessageId(msgId));
            foreach(attach; emailSummary.attachFileNames)
            {
                if (countUntil(ret.attachFileNames, attach) == -1)
                    ret.attachFileNames ~= attach;
            }
        }
    }
    return ret;
}


Conversation getConversation(string id)
{
    auto convDoc = g_mongoDB["conversation"].findOne(["_id": id]);
    return conversationDocToObject(convDoc);
}


const(Conversation[]) getConversationsByTag(string tagName, uint limit, uint page)
{
    const(Conversation)[] ret;

    auto jsonFind = parseJsonString(format(`{"tags": {"$in": ["%s"]}}`, tagName));
    auto cursor   = g_mongoDB["conversation"].find(
                                                   jsonFind,
                                                   Bson(null),
                                                   QueryFlags.None,
                                                   page > 0? page*limit: 0 // skip
    ).sort(["lastDate": -1]);

    cursor.limit(limit);
    foreach(ref doc; cursor)
        ret ~= conversationDocToObject(doc);
    return ret;
}


/**
 * Return the first Conversation that has ANY of the references contained in its
 * links
 */
Conversation getConversationByReferences(string userId, const string[] references)
{
    string[] reversed = references.dup;
    reverse(reversed);

    auto convDoc = g_mongoDB["conversation"].findOne(
        parseJsonString(
            format(`{"userId": "%s", "links.message-id": {"$in": %s}}`, userId, reversed)
        )
    );
    return conversationDocToObject(convDoc);
}

/**
 * From removes variants of "Re:"/"RE:"/"re:" in the subject
 */
private string cleanSubject(string subject)
{
    return replaceAll!(x => "")(subject, SUBJECT_CLEAN_REGEX);
}


/**
 * Insert or update a conversation with this email messageId, references, tags
 * and date
*/
string upsertConversation(const IncomingEmail email, string emailDbId,
                          string userId, const bool[string] tags)
{
    const references = email.getHeader("references").addresses;
    const messageId  = email.getHeader("message-id").addresses[0];

    auto conv = getConversationByReferences(userId, references ~ messageId);
    conv.userDbId = userId;

    // date: will only be set if newer than lastDate
    conv.updateLastDate(BsonDate(SysTime(email.date,
                                         TimeZone.getTimeZone("GMT"))).toString);

    // tags
    foreach(tagName, tagValue; tags)
        if (tagValue && countUntil(conv.tags, tagName) == -1)
            conv.tags ~= tagName;

    // add our references; addLink() only adds the new ones
    foreach(reference; references)
        conv.addLink(reference, getEmailIdByMessageId(reference));

    bool wasInConversation = false;
    if (conv.dbId.length)
    {
        // existing conversation: see if this email msgid is on the conversation links,
        // (can happen if an email referring to this one entered the system before this
        // email); if so update the conversation with the EmailId
        foreach(ref entry; conv.links)
        {
            if (entry.messageId == messageId)
            {
                entry.emailDbId = emailDbId;
                wasInConversation = true;
                break;
            }
        }
    }
    else
        conv.dbId = BsonObjectID.generate().toString;

    if (!wasInConversation)
        conv.addLink(messageId, emailDbId);

    // update the conversation cleaned subject (last one wins)
    if (email.hasHeader("subject"))
        conv.cleanSubject = cleanSubject(email.getHeader("subject").rawValue);

    g_mongoDB["conversation"].update(["_id": conv.dbId],
                                     parseJsonString(conv.toJson),
                                     UpdateFlags.Upsert);
    return conv.dbId;
}


void store(ref Envelope envelope)
{
    envelope.dbId = BsonObjectID.generate().toString;
    g_mongoDB["envelope"].insert(parseJsonString(envelope.toJson));
}


string getUserIdFromAddress(string address)
{
    auto userResult = g_mongoDB["user"].findOne(
            parseJsonString(format(`{"addresses": {"$in": ["%s"]}}`, address)),
            ["_id": 1],
            QueryFlags.None
    );
    return userResult.isNull? "": bsonStr(userResult._id);
}


string store(IncomingEmail email)
{
    // json for the text parts
    auto partAppender = appender!string;
    foreach(idx, part; email.textualParts)
        partAppender.put("{\"contentType\": " ~ Json(part.ctype.name).toString() ~ ","
                          "\"content\": "     ~ Json(part.textContent).toString() ~ "},");
    string textPartsJsonStr = partAppender.data.idup;
    partAppender.clear();

    // json for the attachments
    foreach(ref attach; email.attachments)
    {
        partAppender.put(`{"contentType": ` ~ Json(attach.ctype).toString()     ~ `,` ~
                         ` "realPath": `    ~ Json(attach.realPath).toString()  ~ `,` ~
                         ` "size": `        ~ Json(attach.size).toString()      ~ `,`);
        if (attach.contentId.length)
            partAppender.put(` "contentId": ` ~ Json(attach.contentId).toString() ~ `,`);
        if (attach.filename.length)
            partAppender.put(` "fileName": `  ~ Json(attach.filename).toString()  ~ `,`);
        partAppender.put("},");
    }
    string attachmentsJsonStr = partAppender.data().idup;
    partAppender.clear();

    // Some emails doesnt have a "To:" header but a "Delivered-To:". Really!
    string realReceiverField, realReceiverRawValue, realReceiverAddresses;
    if (email.hasHeader("to"))
        realReceiverField = "to";
    else if (email.hasHeader("bcc"))
        realReceiverField = "bcc";
    else if (email.hasHeader("delivered-to"))
        realReceiverField = "delivered-to";
    else
    {
        auto err = "Cant insert to DB email without destination";
        logError(err);
        throw new Exception(err);
    }
    realReceiverRawValue = email.jsonizeHeader(realReceiverField,
                                               No.RemoveQuotes,
                                               Yes.OnlyValue);
    realReceiverAddresses = to!string(email.getHeader(realReceiverField).addresses);

    // Json for the headers
    // (see the schema.txt doc)
    bool[string] alreadyDone;
    partAppender.put("{");
    foreach(headerName, ref headerValue; email.headers)
    {
        if (among(toLower(headerName), "from", "message-id"))
            // these are outside headers because they're indexed
            continue;

        // email.headers can have several values per key and thus be repeated
        // in the foreach iteration but we extract all the first time
        if (headerName in alreadyDone)
            continue;
        alreadyDone[headerName] = true;

        auto allValues = email.headers.getAll(headerName);
        partAppender.put(format(`"%s": [`, toLower(headerName)));
        foreach(ref hv; allValues)
        {
            partAppender.put(format(`{"rawValue": %s`, Json(hv.rawValue).toString));
            if (hv.addresses.length)
                partAppender.put(format(`,"addresses": %s`, to!string(hv.addresses)));
            partAppender.put("},");
        }
        partAppender.put("],");
    }
    partAppender.put("}");
    string rawHeadersStr = partAppender.data();
    partAppender.clear();

    auto relevantPlain = maybeBodyTextPlain(email);
    auto bodyPeek = relevantPlain.length?
                        relevantPlain[0..min($,getConfig().bodyPeekLength)]:
                        "";

    const documentId = BsonObjectID.generate().toString;
    auto emailInsertJson = format(
          `{"_id": "%s",` ~
          `"rawEmailPath": "%s",` ~
          `"message-id": "%s",`    ~
          `"isodate": "%s",`      ~
          `"from": { "rawValue": %s "addresses": %s },` ~
          `"receivers": { "rawValue": %s "addresses": %s },`   ~
          `"headers": %s, `    ~
          `"textParts": [ %s ], ` ~
          `"bodyPeek": "%s", ` ~
          `"attachments": [ %s ] }`,
            documentId,
            email.rawEmailPath,
            email.getHeader("message-id").addresses[0],
            BsonDate(SysTime(email.date, TimeZone.getTimeZone("GMT"))).toString,
            email.jsonizeHeader("from", No.RemoveQuotes, Yes.OnlyValue),
            to!string(email.getHeader("from").addresses),
            realReceiverRawValue,
            realReceiverAddresses,
            rawHeadersStr,
            textPartsJsonStr,
            bodyPeek,
            attachmentsJsonStr
    );
    g_mongoDB["email"].insert(parseJsonString(emailInsertJson));
    return documentId;
}


private string storeTextIndexMongo(string content, string emailDbId)
{
    auto docId = BsonObjectID.generate().toString;
    g_mongoDB["emailIndexContents"].insert(["_id": docId,
                                          "text": content,
                                          "emailDbId": emailDbId,
                                         ]);
    return docId;
}


/** Try to guess the relevant part of the email body and return it as plain text
 */
string maybeBodyTextPlain(const IncomingEmail email)
{
    if (!email.textualParts.length)
        return "";

    auto partAppender = appender!string;

    if (email.textualParts.length == 2 &&
        email.textualParts[0].ctype.name != email.textualParts[1].ctype.name &&
        among(email.textualParts[0].ctype.name, "text/plain", "text/html") &&
        among(email.textualParts[1].ctype.name, "text/plain", "text/html"))
    {
        // one html and one plain part, almost certainly related, store the plain one
        partAppender.put(email.textualParts[0].ctype.name == "text/plain"?
                                                email.textualParts[0].textContent:
                                                email.textualParts[1].textContent);
    }
    else
    {
        // append and store all parts
        foreach(part; email.textualParts)
        {
            if (part.ctype.name == "text/html")
                partAppender.put(htmlToText(part.textContent));
            else
                partAppender.put(part.textContent);
        }
    }
    return strip(partAppender.data);
}


/**
 * Store a document with the relevant textual part of the email body.
 */
void storeTextIndex(const IncomingEmail email, string emailDbId)
{
    if (!email.textualParts.length)
        return;

    auto maybeText = maybeBodyTextPlain(email);
    if (maybeText.length)
        storeTextIndexMongo(maybeText, emailDbId);
}


/**
    Search for an equal email on the DB, comparing all relevant fields
*/
Flag!"AlreadyOnDb" emailAlreadyOnDb(const IncomingEmail email)
{
    const emailInDb = g_mongoDB["email"].findOne(
            ["message-id": email.getHeader("message-id").addresses[0]],
            ["headers": 1, "from": 1, "receivers": 1],
            QueryFlags.None
    );
    if (emailInDb.isNull)
        return No.AlreadyOnDb;

    if (
       email.getHeader("subject").rawValue != bsonStr(emailInDb.headers.subject[0].rawValue)
      || email.getHeader("from").rawValue  != bsonStr(emailInDb.from.rawValue)
      || email.getHeader("to").rawValue    != bsonStr(emailInDb.receivers.rawValue)
      || email.getHeader("date").rawValue  != bsonStr(emailInDb.headers.date[0].rawValue))
        return No.AlreadyOnDb;
    return Yes.AlreadyOnDb;
}


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(db_usetestdb) string[] TEST_EMAILS = ["multipart_mixed_rel_alternative_attachments",
                                               "simple_alternative_noattach",
                                               "spam_tagged",
                                               "with_2megs_attachment",
                                               "spam_notagged_nomsgid"];
version(db_usetestdb)
{
    void insertTestSettings()
    {
        g_mongoDB["settings"].remove();
        string settingsJsonStr = format(`
        {
                "_id"                  : "5399793904ac3d27431d0669",
                "mainDir"              : "/home/juanjux/webmail",
                "attachmentStore"      : "backend/test/attachments",
                "incomingMessageLimit" : 15728640,
                "storeTextIndex"       : true,
                "module"               : "retriever",
                "rawEmailStore"        : "backend/test/rawemails",
                "smtpEncription"       : 0,
                "smtpPass"             : "smtpPass",
                "smtpPort"             : 25,
                "smtpServer"           : "localhost",
                "smtpUser"             : "smtpUser",
                "bodyPeekLength"       : 100
        }`);
        g_mongoDB["settings"].insert(parseJsonString(settingsJsonStr));
    }


    void recreateTestDb()
    {
        foreach(string collection; ["envelope", "email", "emailIndexContents",
                                    "conversation", "domain", "user", "userrule"])
            g_mongoDB[collection].remove();

        // Fill the test DB
        string backendTestDataDir_ = 
            buildPath(getConfig().mainDir, "backend", "test", "testdb");
        string[string] jsonfile2collection = ["user1.json"     : "user",
                                              "user2.json"     : "user",
                                              "domain1.json"   : "domain",
                                              "domain2.json"   : "domain",
                                              "userrule1.json" : "userrule",
                                              "userrule2.json" : "userrule",];
        foreach(file_, collection; jsonfile2collection)
            g_mongoDB[collection].insert(parseJsonString(readText(buildPath(backendTestDataDir_, file_))));

        string backendTestEmailsDir = 
            buildPath(getConfig().mainDir, "backend", "test", "testemails");
        foreach(mailname; TEST_EMAILS)
        {
            auto email = new IncomingEmailImpl();
            email.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                                         getConfig().attachmentStore);
            assert(email.isValid, "Email is not valid");
            auto destination = email.getHeader("to").addresses[0];
            auto emailId     = email.store();
            auto userId      = getUserIdFromAddress(destination);
            auto envelope    = Envelope(email, destination, userId, emailId);
            auto date        = BsonDate(SysTime(email.date,
                                                TimeZone.getTimeZone("GMT"))).toString;

            envelope.store();
            upsertConversation(email, emailId, userId, ["inbox": true]);
            storeTextIndex(email, emailId);
        }
    }
}

version(db_test)
{
    unittest // domainHasDefaultUser
    {
        writeln("Testing domainHasDefaultUser");
        recreateTestDb();
        assert(domainHasDefaultUser("testdatabase.com")  == Yes.HasDefaultUser, "domainHasDefaultUser1");
        assert(domainHasDefaultUser("anotherdomain.com") == No.HasDefaultUser, "domainHasDefaultUser2");
    }

    unittest // getAddressFilters
    {
        writeln("Testing getAddressFilters");
        recreateTestDb();
        auto filters = getAddressFilters("testuser@testdatabase.com");
        assert(filters.length == 1);
        assert(!filters[0].match.withAttachment);
        assert(!filters[0].match.withHtml);
        assert(filters[0].match.totalSizeType        == SizeRuleType.GreaterThan);
        assert(filters[0].match.totalSizeValue       == 100485760);
        assert(filters[0].match.bodyMatches.length   == 1);
        assert(filters[0].match.bodyMatches[0]       == "XXXBODYMATCHXXX");
        assert(filters[0].match.headerMatches.length == 1);
        assert("From" in filters[0].match.headerMatches);
        assert(filters[0].match.headerMatches["From"] == "juanjo@juanjoalvarez.net");
        assert(!filters[0].action.forwardTo.length);
        assert(!filters[0].action.noInbox);
        assert(filters[0].action.markAsRead);
        assert(!filters[0].action.deleteIt);
        assert(filters[0].action.neverSpam);
        assert(!filters[0].action.setSpam);
        assert(filters[0].action.addTags == ["testtag1", "testtag2"]);
        auto filters2 = getAddressFilters("anotherUser@anotherdomain.com");
        assert(filters2[0].action.addTags == ["testtag3", "testtag4"]);
        auto newfilters = getAddressFilters("anotherUser@testdatabase.com");
        assert(filters2[0].action.addTags == newfilters[0].action.addTags);
    }

    unittest // addressIsLocal
    {
        writeln("Testing addressIsLocal");
        recreateTestDb();
        assert(addressIsLocal("testuser@testdatabase.com"));
        assert(addressIsLocal("random@testdatabase.com")); // has default user
        assert(addressIsLocal("anotherUser@testdatabase.com"));
        assert(addressIsLocal("anotherUser@anotherdomain.com"));
        assert(!addressIsLocal("random@anotherdomain.com"));
    }

    unittest // jsonizeHeader
    {
        writeln("Testing jsonizeHeader");
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");
        auto email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "simple_alternative_noattach"),
                           getConfig().attachmentStore);
        assert(email.jsonizeHeader("from") == `"from": " Test Sender <someuser@insomedomain.com>",`);
        assert(email.jsonizeHeader("to")   == `"to": " Test User2 <testuser@testdatabase.com>",`);
        assert(email.jsonizeHeader("Date", Yes.RemoveQuotes, Yes.OnlyValue) == `" Sat, 25 Dec 2010 13:31:57 +0100",`);
    }

    unittest // email.store()
    {
        writeln("Testing email.store");
        recreateTestDb();
        auto cursor = g_mongoDB["email"].find();
        cursor.sort(parseJsonString(`{"_id": 1}`));
        assert(!cursor.empty);
        auto emailDoc = cursor.front; // email 0
        assert(emailDoc.headers.references[0].addresses.length == 1);
        assert(bsonStr(emailDoc.headers.references[0].addresses[0]) == "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        assert(bsonStr(emailDoc.headers.subject[0].rawValue) == " Fwd: Se ha evitado un inicio de sesión sospechoso");
        assert(emailDoc.attachments.length == 2);
        assert(bsonStr(emailDoc.isodate) == "2013-05-27T05:42:30Z");
        assert(bsonStr(emailDoc.receivers.addresses[0]) == "testuser@testdatabase.com");
        assert(bsonStr(emailDoc.from.addresses[0]) == "someuser@somedomain.com");
        assert(emailDoc.textParts.length == 2);
        assert(bsonStr(emailDoc.bodyPeek) == "Some text inside the email plain part");

        // check generated msgid
        cursor.popFrontExactly(countUntil(TEST_EMAILS, "spam_notagged_nomsgid"));
        assert(bsonStr(cursor.front["message-id"]).length);
        assert(bsonStr(cursor.front.bodyPeek) == "Well it is speculated that there are over 20,000 hosting companies in this country alone. WIth that ");
    }

    unittest // emailAlreadyOnDb
    {
        writeln("Testing emailAlreadyOnDb");
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir,
                                                "backend", "test", "testemails");
        // ignore the nomsgid email (last one) since it cant be checked to be on DB
        foreach(mailname; TEST_EMAILS[0..$-1])
        {
            auto email = new IncomingEmailImpl();
            email.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                                         getConfig().attachmentStore);
            assert(emailAlreadyOnDb(email));
        }
    }

    unittest // storeTextIndex
    {
        writeln("Testing storeTextIndexMongo");
        recreateTestDb();
        auto findJson = format(`{"$text": {"$search": "DOESNTEXISTS"}}`);
        auto cursor = g_mongoDB["emailIndexContents"].find(parseJsonString(findJson));
        assert(cursor.empty);

        findJson = format(`{"$text": {"$search": "text inside"}}`);
        cursor = g_mongoDB["emailIndexContents"].find(parseJsonString(findJson));
        assert(!cursor.empty);
        string res = cursor.front.text.toString;
        assert(countUntil(res, "text inside") == 6);

        findJson = format(`{"$text": {"$search": "email"}}`);
        cursor = g_mongoDB["emailIndexContents"].find(parseJsonString(findJson));
        assert(!cursor.empty);
        assert(countUntil(toLower(cursor.front.text.toString), "email") != -1);
        cursor.popFront;
        assert(countUntil(toLower(cursor.front.text.toString), "email") != -1);
        cursor.popFront;
        assert(cursor.empty);
    }

    unittest // envelope.store()
    {
        writeln("Testing envelope.store");
        import std.exception;
        import core.exception;
        recreateTestDb();
        auto cursor = g_mongoDB["envelope"].find(
               ["destinationAddress": "testuser@testdatabase.com"]
        );
        assert(!cursor.empty);
        auto envDoc = cursor.front;
        cursor.popFrontExactly(2);
        assert(cursor.empty);
        assert(collectException!AssertError(cursor.popFront));
        assert(envDoc.forwardTo.type == Bson.Type.array);
        auto userId = getUserIdFromAddress("testuser@testdatabase.com");
        assert(bsonStr(envDoc.userId) == userId);
        auto emailId = getEmailIdByMessageId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(bsonStr(envDoc.emailId) == emailId);
    }

    unittest // getEmailIdByMessageId
    {
        writeln("Testing getEmailIdByMessageId");
        recreateTestDb();
        auto id1 = getEmailIdByMessageId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        auto id2 = getEmailIdByMessageId("AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        auto id3 = getEmailIdByMessageId("CAGA-+RScZe0tqmG4rbPTSrSCKT8BmkNAGBUOgvCOT5ywycZzZA@mail.gmail.com");
        auto id4 = getEmailIdByMessageId("doesntexist");

        assert(id4 == "");
        assert((id1.length == id2.length) && (id3.length == id1.length) && id1.length == 24);
        auto arr = [id1, id2, id3, id4];
        assert(count(arr, id1) == 1);
        assert(count(arr, id2) == 1);
        assert(count(arr, id3) == 1);
        assert(count(arr, id4) == 1);
    }

    unittest // upsertConversation
    {
        writeln("Testing upsertConversation");
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                               "testemails");
        auto email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                                     getConfig().attachmentStore);
        auto emailObjectDate = BsonDate(SysTime(email.date,
                                                TimeZone.getTimeZone("GMT")))
                                               .toString;

        auto userId = getUserIdFromAddress(email.getHeader("to").addresses[0]);
        bool[string] tags = ["inbox": true, "dontstore": false, "anothertag": true];
        // test1: insert as is, should create a new conversation with this email as single member
        auto emailId = email.store();
        auto convId = upsertConversation(email, emailId, userId, tags);
        auto convDoc = g_mongoDB["conversation"].findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type      == Bson.Type.array);
        assert(convDoc.links.length    == 1);
        assert(bsonStr(convDoc.links[0]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[0].emailId)       == emailId);
        assert(convDoc.tags.type == Bson.Type.Array);
        assert(convDoc.tags.length == 2);
        assert(bsonStrArray(convDoc.tags)[0] == "inbox");
        assert(bsonStrArray(convDoc.tags)[1] == "anothertag");
        assert(bsonStr(convDoc.lastDate) == emailObjectDate);

        auto convObject = getConversation(convId);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == userId);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[0].messageId == email.getHeader("message-id").addresses[0]);
        assert(convObject.links[0].emailDbId == emailId);
        assert(!convObject.attachFileNames.length);


        // test2: insert as a msgid of a reference already on a conversation, check that the right
        // conversationId is returned and the emailId added to its entry in the conversation.links
        recreateTestDb();
        email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        email.headers["message-id"].addresses[0] = "testreference@blabla.testdomain.com";
        emailId = email.store();
        convId = upsertConversation(email, emailId, userId, tags);
        convDoc = g_mongoDB["conversation"].findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 3);
        assert(bsonStr(convDoc.links[1]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != emailObjectDate);

        convObject = getConversation(convId);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == userId);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[1].messageId == email.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].emailDbId == emailId);
        assert(!convObject.attachFileNames.length);

        // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
        // is added to that conversation
        recreateTestDb();
        email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                           getConfig().attachmentStore);
        string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
        email.addHeader(refHeader);
        emailId = email.store();
        convId = upsertConversation(email, emailId, userId, tags);
        convDoc = g_mongoDB["conversation"].findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 2);
        assert(bsonStr(convDoc.links[1]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
        assert(bsonStr(convDoc.lastDate) != emailObjectDate);

        convObject = getConversation(convId);
        assert(convObject.dbId == convId);
        assert(convObject.userDbId == userId);
        assert(convObject.lastDate == bsonStr(convDoc.lastDate));
        foreach(tag; convObject.tags)
            assert(tag in tags);
        assert(convObject.links[1].messageId == email.getHeader("message-id").addresses[0]);
        assert(convObject.links[1].emailDbId == emailId);
        assert(convObject.attachFileNames.length == 1);
        assert(convObject.attachFileNames[0] == "C++ Pocket Reference.pdf");
    }

    unittest // getConversation/getEmailSummary/conversationDocToObject
    {
        writeln("Testing getConversation/getEmailSummary/conversationDocToObject");
        recreateTestDb();

        auto convs = getConversationsByTag("inbox", 0, 0);
        auto conv = getConversation(convs[0].dbId);
        assert(conv.lastDate.length); // this email date is set to NOW
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 1);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Tired of Your Hosting Company?");

        conv = getConversation(convs[1].dbId);
        assert(conv.lastDate == "2014-06-10T12:51:10Z");
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 3);
        assert(!conv.attachFileNames.length);
        assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");

        conv = getConversation(convs[2].dbId);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tags == ["inbox"]);
        assert(conv.links.length == 1);
        assert(conv.attachFileNames.length == 1);
        assert(conv.attachFileNames[0] == "C++ Pocket Reference.pdf");
        assert(conv.cleanSubject == " Attachment test");
    }

    unittest // getApiEmail
    {
        import std.digest.md;
        writeln("Testing getApiEmail");
        recreateTestDb();

        auto convs = getConversationsByTag("inbox", 0, 0);
        auto conv = getConversation(convs[2].dbId);
        auto apiEmail = getApiEmail(conv.links[0].emailDbId);
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
    }

    unittest // getConversationsByTag
    {
        writeln("Testing getConversationsByTag");
        recreateTestDb();
        auto convs = getConversationsByTag("inbox", 0, 0);
        assert(convs.length == 4);
        assert(convs[0].lastDate > convs[3].lastDate);

        auto convs2 = getConversationsByTag("inbox", 2, 0);
        assert(convs2.length == 2);
        assert(convs2[0].dbId == convs[0].dbId);
        assert(convs2[1].dbId == convs[1].dbId);

        auto convs3 = getConversationsByTag("inbox", 2, 1);
        assert(convs3.length == 2);
        assert(convs3[0].dbId == convs[2].dbId);
        assert(convs3[1].dbId == convs[3].dbId);

        auto convs4 = getConversationsByTag("inbox", 1000, 0);
        assert(convs4 == convs);

    }

    unittest // getConversationByReferences
    {
        writeln("Testing getConversationByReferences");
        recreateTestDb();
        auto userId1 = getUserIdFromAddress("testuser@testdatabase.com");
        auto userId2 = getUserIdFromAddress("anotherUser@testdatabase.com");
        assert(userId1.length);
        assert(userId2.length);

        auto conv = getConversationByReferences(userId1, ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2013-05-27T05:42:30Z");
        assert(conv.tags.length == 1);
        assert(conv.tags[0] == "inbox");
        assert(conv.links.length == 2);
        assert(conv.links[1].messageId == "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[1].emailDbId.length);


        conv = getConversationByReferences(userId2, ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv.dbId.length);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tags.length == 1);
        assert(conv.tags[0] == "inbox");
        assert(conv.links.length == 1);
        assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
    }
}


version(db_insertalltest) unittest
{
    writeln("Testing Inserting Everything");
    version(db_usetestdb)
        recreateTestDb();
    import std.datetime;
    import std.process;

    string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
    string origEmailDir    = buildPath(backendTestDir, "emails", "single_emails");
    string rawEmailStore   = buildPath(backendTestDir, "rawemails");
    string attachmentStore = buildPath(backendTestDir, "attachments");
    int[string] brokenEmails;
    StopWatch sw;
    StopWatch totalSw;
    ulong totalTime = 0;
    ulong count = 0;

    foreach (ref DirEntry e; getSortedEmailFilesList(origEmailDir))
    {
        //if (indexOf(e, "62877") == -1) continue; // For testing a specific email
        //if (to!int(e.name.baseName) < 62879) continue; // For testing from some email forward
        writeln(e.name, "...");

        totalSw.start();
        if (baseName(e.name) in brokenEmails)
            continue;
        auto email = new IncomingEmailImpl();

        sw.start();
        email.loadFromFile(File(e.name), attachmentStore);
        sw.stop(); writeln("loadFromFile time: ", sw.peek().usecs); sw.reset();


        sw.start();
        auto localReceivers = localReceivers(email);
        if (!localReceivers.length)
        {
            writeln("SKIPPING, not local receivers");
            continue; // probably a message from the "sent" folder
        }

        //auto email_withcopy = new IncomingEmailImpl(rawEmailStore, attachmentStore);
        //sw.start();
        //email_withcopy.loadFromFile(File(e.name), true);
        //sw.stop(); writeln("loadFromFile_withCopy time: ", sw.peek().usecs); sw.reset();

        auto envelope = Envelope(email, localReceivers[0]);
        envelope.userId = getUserIdFromAddress(envelope.destination);
        assert(envelope.userId.length,
              "Please replace the destination in the test emails, not: " ~
              envelope.destination);
        sw.stop(); writeln("getUserIdFromAddress time: ", sw.peek().usecs); sw.reset();

        if (email.isValid == Yes.IsValidEmail)
        {
            writeln("Subject: ", email.getHeader("subject").rawValue);

            sw.start();
            envelope.emailId = email.store();
            sw.stop(); writeln("email.store(): ", sw.peek().usecs); sw.reset();

            sw.start();
            envelope.store();
            sw.stop(); writeln("envelope.store(): ", sw.peek().usecs); sw.reset();

            sw.start();
            auto convId = upsertConversation(email, envelope.emailId, envelope.userId,
                    ["inbox": true]);


            sw.stop(); writeln("Conversation: ", convId, " time: ", sw.peek().usecs); sw.reset();

            sw.start();
            storeTextIndex(email, envelope.emailId);

            sw.stop(); writeln("storeTextIndex: ", sw.peek().usecs); sw.reset();
        }
        else
            writeln("SKIPPING, invalid email");

        totalSw.stop();
        if (email.isValid == Yes.IsValidEmail)
        {
            auto emailTime = totalSw.peek().usecs;
            totalTime += emailTime;
            ++count;
            writeln("Total time for this email: ", emailTime);
        }
        writeln("Valid emails until now: ", count); writeln;
        totalSw.reset();
    }

    writeln("Total number of valid emails: ", count);
    writeln("Average time per valid email: ", totalTime/count);

    // Clean the attachment and rawEmail dirs
    system(format("rm -f %s/*", attachmentStore));
    system(format("rm -f %s/*", rawEmailStore));
}


version(userrule_test) unittest
{
    version(db_usetestdb)
        recreateTestDb();
    writeln("Starting userrule.d unittests...");
    auto config = getConfig();
    auto testDir = buildPath(config.mainDir, "backend", "test");
    auto testEmailDir = buildPath(testDir, "testemails");
    bool[string] tags;

    Envelope reInstance(Match match, Action action)
    {
        auto email = new IncomingEmailImpl();
        email.loadFromFile(buildPath(testEmailDir, "with_2megs_attachment"),
                           buildPath(testDir, "attachments"));
        auto envelope = Envelope(email, "foo@foo.com");
        auto filter   = new UserFilter(match, action);
        tags = ["inbox": true];
        filter.apply(envelope, tags);
        return envelope;
    }

    // Match the From, set unread to false
    Match match; match.headerMatches["from"] = "someuser@somedomain.com";
    Action action; action.markAsRead = true;
    auto envelope = reInstance(match, action);
    assert("unread" in tags && !tags["unread"]);

    // Fail to match the From
    Match match2; match2.headerMatches["from"] = "foo@foo.com";
    Action action2; action2.markAsRead = true;
    auto envelope2 = reInstance(match2, action2);
    assert("unread" !in tags);

    // Match the withAttachment, set inbox to false
    Match match3; match3.withAttachment = true;
    Action action3; action3.noInbox = true;
    auto envelope3 = reInstance(match3, action3);
    assert("inbox" in tags && !tags["inbox"]);

    // Match the withHtml, set deleted to true
    Match match4; match4.withHtml = true;
    Action action4; action4.deleteIt = true;
    auto envelope4 = reInstance(match4, action4);
    assert("deleted" in tags && tags["deleted"]);

    // Negative match on body
    Match match5; match5.bodyMatches = ["nomatch_atall"];
    Action action5; action5.deleteIt = true;
    auto envelope5 = reInstance(match5, action5);
    assert("deleted" !in tags);

    //Match SizeGreaterThan, set tag
    Match match6;
    match6.totalSizeType = SizeRuleType.GreaterThan;
    match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
    Action action6; action6.addTags = ["testtag1", "testtag2"];
    auto envelope6 = reInstance(match6, action6);
    assert("testtag1" in tags && "testtag2" in tags);

    //Dont match SizeGreaterThan, set tag
    auto size1 = envelope6.email.computeSize();
    auto size2 = 2*1024*1024;
    Match match7;
    match7.totalSizeType = SizeRuleType.GreaterThan;
    match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
    Action action7; action7.addTags = ["testtag1", "testtag2"];
    auto envelope7 = reInstance(match7, action7);
    assert("testtag1" !in tags && "testtag2" !in tags);

    // Match SizeSmallerThan, set forward
    Match match8;
    match8.totalSizeType = SizeRuleType.SmallerThan;
    match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
    Action action8;
    action8.forwardTo = ["juanjux@yahoo.es"];
    auto envelope8 = reInstance(match8, action8);
    assert(envelope8.forwardTo[0] == "juanjux@yahoo.es");

    // Dont match SizeSmallerTham
    Match match9;
    match9.totalSizeType = SizeRuleType.SmallerThan;
    match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
    Action action9;
    action9.forwardTo = ["juanjux@yahoo.es"];
    auto envelope9 = reInstance(match9, action9);
    assert(!envelope9.forwardTo.length);
}
