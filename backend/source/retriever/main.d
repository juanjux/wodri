#!/usr/bin/env rdmd
module retriever.main;

import std.stdio;
import std.regex;
import std.conv;
import std.algorithm;
import std.file;
import std.array;
import std.string;
import std.path;

import vibe.core.log;

import retriever.incomingemail;
import retriever.config;
import retriever.userrule;


bool hasValidDestination(IncomingEmail email, string[][string] validDestinations)
// Checks if there is at least one valid destination (user managed by us) 
{
    string[] addresses;

    foreach(string header; ["To", "Cc", "Bcc", "Delivered-To"])
        addresses ~= email.extractAddressesFromHeader(header);

    string user, domain;
    foreach(string addr; addresses)
    {
        auto addrtokens = addr.split("@");

        if (addrtokens.length != 2)
            continue;

        user   = addrtokens[0];
        domain = toLower(addrtokens[1]);

        if (domain in validDestinations && find(validDestinations[domain], user).length)
            return true;
    }
    return false;
}


int main()
{
    auto config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), LogLevel.trace);

    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    mail.loadFromFile(std.stdio.stdin);
    bool isValid             = mail.isValid;
    bool hasValidDestination = hasValidDestination(mail, config.validDestinations);

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

    return 0; // return != 0 == Postfix rebound. Avoid
}
