#!/usr/bin/env rdmd
module retriever.main;

import std.stdio; // XXX debug
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

    foreach(string header; ["To", "Cc", "Bcc", "Delivered-To"])
        addresses ~= email.extractAddressesFromHeader(header);

    // XXX siguiente: generar la cadena, poniendo las addresses en el in con un appender
    auto jsonStr    = `{"addresses": {"$in": ["testuser@juanjux.mooo.com", "juanjux@juanjux.mooo.com"]}}`;
    auto jusr       = parseJsonString(jsonStr);
    auto addrResult = db["user"].findOne(jusr);

    if (addrResult != Bson(null))
        return true;

    return false;
}


int main()
{
    auto db     = connectMongoDB("localhost").getDatabase("webmail");
    auto config = getConfig(db);
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), LogLevel.trace);

    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    mail.loadFromFile(std.stdio.stdin);

    bool isValid             = mail.isValid;
    bool hasValidDestination = hasValidDestination(mail, db);

    // XXX Comprobar tamanio de emails entrantes con el config.incomingMessageLimit y rebotar en ese caso
    if (isValid && hasValidDestination)
    {
        if ("X-Spam-SetSpamTag" in mail.headers)
            mail.tags["spam"] = true;
    }
    else
    {
        auto failedMailDir = buildPath(config.mainDir, "backend", "log", "failed_mails");
        if (!failedMailDir.exists)
            mkdir(failedMailDir);

        auto failedMailPath = buildPath(failedMailDir, baseName(mail.rawMailPath));
        copy(mail.rawMailPath, failedMailPath);
        remove(mail.rawMailPath);

        auto f = File(failedMailPath, "a");
        f.writeln("\n\n===NOT DELIVERY BECAUSE OF===", !isValid?"\nInvalid headers":"",
                  !hasValidDestination?"\nInvalid destination":"");

        logDebug(format("Mesage denied from SMTP. ValidHeaders:%s SomeValidDestination:%s." ~
                         "Message copy stored at %s", isValid, hasValidDestination, failedMailPath));
    }

    return 0; // return != 0 == Postfix rebound the message. Avoid
}
