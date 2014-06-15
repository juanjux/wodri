#!/usr/bin/env rdmd
module retriever.main;

import std.stdio;
import std.path;
import std.file;
import std.string;
import vibe.core.log;
import vibe.db.mongo.mongo;
import retriever.incomingemail;
import retriever.userrule;
import retriever.db;


// FIXME: abstract to db.d so this is independent from the actual DB API used
bool hasValidDestination(IncomingEmail email)
{
    string[] addresses;

    foreach(headerName; ["To", "Cc", "Bcc", "Delivered-To"])
        addresses ~= email.headers[headerName].addresses;

    // Check for a defaultUser ("catch-all") for this domain
    Bson domain;
    auto addrListString = appender!string;
    auto mongoDB = getDatabase();

    foreach(addr; addresses)
    {
        domain = mongoDB["domain"].findOne(["name": toLower(addr.split("@")[1])]);
        if (domain != Bson(null) &&
            domain["defaultUser"] != Bson(null) &&
            domain["defaultUser"].length)
            return true;
        addrListString.put(`"` ~ addr ~ `",`);
    }

    // Check if any of the addresses if one of our users own
    if (addresses.length)
    {
        auto jsonStr    =  `{"addresses": {"$in": [` ~ addrListString.data ~ `]}}`;
        auto addrResult =  mongoDB["user"].findOne(parseJsonString(jsonStr));

        if (addrResult != Bson(null))
            return true;
    }
    return false;
}

// XXX seguir aqui
void saveIncomingEmail(IncomingEmail email)
{
    auto mongoDB = getDatabase();
}


int main()
{
    auto db = getDatabase();
    auto config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), LogLevel.info);

    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    mail.loadFromFile(std.stdio.stdin);

    bool isValid             = mail.isValid;
    bool hasValidDestination = hasValidDestination(mail);
    bool tooBig            = mail.computeSize() > config.incomingMessageLimit;

    if (!tooBig && isValid && hasValidDestination)
    {
        if ("X-Spam-SetSpamTag" in mail.headers)
            mail.tags["spam"] = true;
        // XXX seguir aqui, insertar en BBDD, sacar conversationId e indexar
    }
    else
    {
        auto failedMailDir = buildPath(config.mainDir, "backend", "log", "failed_mails");
        if (!failedMailDir.exists)
            mkdir(failedMailDir);

        // Save a copy of the denied mail in failedMailPath and log the event
        auto failedMailPath = buildPath(failedMailDir, baseName(mail.rawMailPath));
        copy(mail.rawMailPath, failedMailPath);
        remove(mail.rawMailPath);

        auto f = File(failedMailPath, "a");
        f.writeln("\n\n===NOT DELIVERY BECAUSE OF===", !isValid?"\nInvalid headers":"",
                                                       !hasValidDestination?"\nInvalid destination":"",
                                                       tooBig? "\nMessage too big":"");
        logInfo(format("Mesage denied from SMTP. ValidHeaders:%s SomeValidDestination:%s SizeTooBig:%s" ~
                         "Message copy stored at %s", isValid, hasValidDestination, failedMailPath, tooBig));
    }

    return 0; // return != 0 == Postfix rebound the message. Avoid
}

unittest
{
    // XXX TODO
}

