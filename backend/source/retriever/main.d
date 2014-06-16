#!/usr/bin/env rdmd
module retriever.main;

import std.stdio;
import std.path;
import std.file;
import std.string;
import std.conv;
import vibe.core.log;
import retriever.incomingemail;
import retriever.envelope;
import retriever.userrule;
import retriever.db;

version(maintest){}
else version = not_maintest;


string[] removeDups(string[] inputarray)
{
    bool[string] checker;
    string[] res;
    foreach(input; inputarray)
    {
        if (input in checker)
            continue;
        checker[input] = true;
        res ~= input;
    }
    return res;
}


version(maintest)
unittest
{
    writeln("Testing removeDups...");
    string[] foo = ["uno", "one", "one", "dos", "three", "four", "five", "five"];
    assert(removeDups(foo) == ["uno", "one", "dos", "three", "four", "five"]);
}


string saveRejectedEmail(IncomingEmail mail)
{
    auto config = getConfig();
    auto failedMailDir = buildPath(config.mainDir, "backend", "log", "failed_mails");
    if (!failedMailDir.exists)
        mkdir(failedMailDir);

    // Save a copy of the denied mail in failedMailPath and log the event
    auto failedMailPath = buildPath(failedMailDir, baseName(mail.rawMailPath));
    copy(mail.rawMailPath, failedMailPath);
    remove(mail.rawMailPath);
    return failedMailPath;
}


void saveAndLogRejectedMail(IncomingEmail mail, bool isValid, bool tooBig, string[] localReceivers)
{
    auto failedMailPath = saveRejectedEmail(mail);
    auto f = File(failedMailPath, "a");
    f.writeln("\n\n===NOT DELIVERY BECAUSE OF===", !isValid?"\nInvalid headers":"",
                                                   !localReceivers.length?"\nInvalid destination":"",
                                                   tooBig? "\nMessage too big":"");
    logInfo(format("Mesage denied from SMTP. ValidHeaders:%s #localReceivers:%s SizeTooBig:%s. " ~
                     "Message copy stored at %s", isValid, localReceivers.length, tooBig, failedMailPath));

}


// XXX add unittest when I've the testing dB
string[] localReceivers(IncomingEmail email)
{
    string[] allAddresses;
    string[] localAddresses;

    foreach(headerName; ["To", "Cc", "Bcc", "Delivered-To"])
    {
        if (headerName in email.headers)
            allAddresses ~= email.headers[headerName].addresses;
    }

    // Check for a defaultUser ("catch-all") for this domain
    foreach(addr; allAddresses)
        if (addressIsLocal(addr))
            localAddresses ~= addr;

    return localAddresses;
}


void processMailForAddress(string destination, IncomingEmail mail)
{
    auto envelope = Envelope(mail, destination);
    envelope.tags["inbox"] = true;

    if ("X-Spam-SetSpamTag" in mail.headers)
        envelope.tags["spam"] = true;

    auto userFilters = getAddressFilters(destination);
    foreach(filter; userFilters) 
        filter.apply(envelope);

    try
    {
        saveEmailToDb(mail, envelope); 
        // XXX index the message
    } catch (Exception e) 
    {
        auto savedPath = saveRejectedEmail(mail);
        string exceptionReport = "Mail failed to save on DB because of exception:\n" ~ e.msg;
        auto f = File(savedPath, "a");
        f.writeln(exceptionReport);
        logError(exceptionReport);
        // XXX rebound the message using the output route
    }
}


// XXX test: validity of the tooBig/isValid/localReceivers checks
version(not_maintest)
int main()
{
    auto config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), LogLevel.info);

    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    mail.loadFromFile(std.stdio.stdin);

    bool isValid        = mail.isValid;
    auto localReceivers = removeDups(localReceivers(mail));
    bool tooBig         = mail.computeSize() > config.incomingMessageLimit;

    if (!tooBig && isValid && localReceivers.length)
        foreach(destination; localReceivers)
            processMailForAddress(destination, mail);
    else
    {
        saveAndLogRejectedMail(mail, isValid, tooBig, localReceivers);
        // XXX rebound the message using the output route
    }
    return 0; // return != 0 == Postfix rebound the message. Avoid
}

unittest
{
}

