#!/usr/bin/env rdmd
module retriever.main;

import std.stdio;
import std.path;
import std.file;
import std.string;
import vibe.core.log;
import vibe.db.mongo.mongo;
import vibe.db.mongo.database;
import retriever.incomingemail;
import retriever.config;
import retriever.userrule;


bool hasValidDestination(IncomingEmail email, MongoDatabase db)
{
    string[] addresses;
    string domain;
    auto addrListString = appender!string;

    foreach(header; ["To", "Cc", "Bcc", "Delivered-To"])
        addresses ~= email.extractAddressesFromHeader(header);

    // Check for a defaultUser ("catch-all") for this domain
    foreach(addr; addresses)
    {
        auto domainRes = db["domain"].findOne(["name": toLower(addr.split("@")[1])]);
        if (domainRes != Bson(null) &&
            domainRes["defaultUser"] != Bson(null) &&
            domainRes["defaultUser"].length)
            return true;
        addrListString.put(`"` ~ addr ~ `",`);
    }

    // Check if any of the addresses if one of our users own
    if (addresses.length)
    {
        auto jsonStr    =  `{"addresses": {"$in": [` ~ addrListString.data ~ `]}}`;
        auto addrResult =  db["user"].findOne(parseJsonString(jsonStr));

        if (addrResult != Bson(null))
            return true;
    }
    return false;
}


int main()
{
    auto db     = connectMongoDB("localhost").getDatabase("webmail");
    auto config = getConfig(db);
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), LogLevel.info);

    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    mail.loadFromFile(std.stdio.stdin);

    bool isValid             = mail.isValid;
    bool hasValidDestination = hasValidDestination(mail, db);
    bool tooBig            = mail.computeSize() > config.incomingMessageLimit;

    if (!tooBig && isValid && hasValidDestination)
    {
        if ("X-Spam-SetSpamTag" in mail.headers)
            mail.tags["spam"] = true;
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

