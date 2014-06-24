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

// XXX test when I've the full cicle tests
string saveRejectedEmail(IncomingEmail email)
{
    auto config = getConfig();
    auto failedEmailDir = buildPath(config.mainDir, "backend", "log", "failed_emails");
    if (!failedEmailDir.exists)
        mkdir(failedEmailDir);

    // Save a copy of the denied email in failedEmailPath and log the event
    auto failedEmailPath = buildPath(failedEmailDir, baseName(email.rawEmailPath));
    copy(email.rawEmailPath, failedEmailPath);
    remove(email.rawEmailPath);
    return failedEmailPath;
}


// XXX test when I've the full cicle tests
void saveAndLogRejectedEmail(IncomingEmail email, bool isValid, bool tooBig,
                            string[] localReceivers, bool alreadyOnDb)
{
    auto failedEmailPath = saveRejectedEmail(email);
    auto f = File(failedEmailPath, "a");
    f.writeln("\n\n===NOT DELIVERY BECAUSE OF===", !isValid? "\nInvalid headers":"",
                                                   !localReceivers.length? "\nInvalid destination":"",
                                                   tooBig? "\nMessage too big":"",
                                                   alreadyOnDb? "\nAlready on DB": "");
    logInfo(format("Message denied from SMTP. ValidHeaders:%s"~
                   "#localReceivers:%s SizeTooBig:%s. AlreadyOnDb: %s" ~
                   "Message copy stored at %s",
                   isValid, localReceivers.length, tooBig, alreadyOnDb, failedEmailPath));
}


// XXX add unittest when I've the testing dB
string[] localReceivers(IncomingEmail email)
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


// XXX test
void processEmailForAddress(string destination, IncomingEmail email, string emailId)
{
    // Create the email=>user envelope
    auto userId            = getUserIdFromAddress(destination);
    auto envelope          = Envelope(email, destination, userId, emailId);
    envelope.tags["inbox"] = true;

    if ("x-spam-setspamtag" in email.headers)
        envelope.tags["spam"] = true;

    // Apply the user-defined filters (if any)
    auto userFilters = getAddressFilters(destination);
    foreach(filter; userFilters)
        filter.apply(envelope);
    storeEnvelope(envelope);

    upsertConversation(email.getHeader("references").addresses, 
                              email.headers["message-id"].addresses[0],
                              emailId, userId);
}

// XXX test when I've the full cycle tests 
version(not_maintest)
int main()
{
    auto config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), LogLevel.info);

    auto email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
    email.loadFromFile(std.stdio.stdin);

    bool isValid        = email.isValid;
    auto localReceivers = removeDups(localReceivers(email));
    bool tooBig         = email.computeSize() > config.incomingMessageLimit;
    bool alreadyOnDb    = email.emailAlreadyOnDb;

    if (!tooBig && isValid && localReceivers.length && !alreadyOnDb)
    {
        try
        {
            auto emailId = storeEmail(email);
            foreach(destination; localReceivers)
                processEmailForAddress(destination, email, emailId);
        } catch (Exception e)
        {
            auto savedPath = saveRejectedEmail(email);
            string exceptionReport = "Email failed to save on DB because of exception:\n" ~ e.msg;
            auto f = File(savedPath, "a");
            f.writeln(exceptionReport);
            logError(exceptionReport);
        }
    }
    else
        // XXX rebound the message using the output route
        saveAndLogRejectedEmail(email, isValid, tooBig, localReceivers, alreadyOnDb);
    return 0; // return != 0 == Postfix rebound the message. Avoid
}



//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


unittest
{
}

