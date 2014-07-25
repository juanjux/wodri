#!/usr/bin/env rdmd
module retriever.main;

import std.stdio;
import std.typecons;
import std.path;
import std.file;
import std.string;
import std.conv;
import std.algorithm: uniq;
import std.array: array;
import vibe.core.log;
import retriever.incomingemail;
import db.conversation;
import db.envelope;
import db.userrule;
import db.mongo;

version(maintest){}
else version = not_maintest;


// XXX test when I've the full cicle tests
string saveRejectedEmail(const IncomingEmail email)
{
    const config = getConfig();
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
void saveAndLogRejectedEmail(const IncomingEmail email, 
                             Flag!"IsValidEmail" isValid, 
                             bool tooBig,
                             const string[] localReceivers, 
                             Flag!"AlreadyOnDb" alreadyOnDb)
{
    auto failedEmailPath = saveRejectedEmail(email);
    auto f = File(failedEmailPath, "a");
    f.writeln("\n\n===NOT DELIVERY BECAUSE OF===", 
                    isValid == No.IsValidEmail? "\nInvalid headers":"",
                    !localReceivers.length? "\nInvalid destination":"",
                    tooBig? "\nMessage too big":"",
                    alreadyOnDb == Yes.AlreadyOnDb? "\nAlready on DB": "");

    logInfo(format("Message denied from SMTP. ValidHeaders:%s "~
                   "numLocalReceivers:%s SizeTooBig:%s. AlreadyOnDb: %s " ~
                   "Message copy stored at %s",
                   isValid, localReceivers.length, tooBig, alreadyOnDb, failedEmailPath));
}


// XXX test when I've the integration tests
void processEmailForAddress(string destination, const IncomingEmail email, string emailId)
{
    // Create the email=>user envelope
    auto userId       = getUserIdFromAddress(destination);
    auto envelope     = Envelope(email, destination, userId, emailId);
    bool[string] tags = ["inbox": true];

    if (email.hasHeader("x-spam-setspamtag"))
        tags["spam"] = true;

    // Apply the user-defined filters (if any)
    const userFilters = getAddressFilters(destination);
    foreach(filter; userFilters)
        filter.apply(envelope, tags);

    envelope.store();
    Conversation.upsert(email, emailId, userId, tags);
    if (getConfig.storeTextIndex)
        storeTextIndex(email, emailId);
}

// XXX test when I've the full cycle tests
version(not_maintest)
int main()
{
    const config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), 
               LogLevel.info);

    auto email = new IncomingEmailImpl();
    email.loadFromFile(std.stdio.stdin, 
                      config.attachmentStore,
                      config.rawEmailStore);

    auto isValid         = email.isValid();
    const localReceivers = uniq(email.localReceivers()).array;
    bool tooBig          = (email.computeSize() > config.incomingMessageLimit);
    auto alreadyOnDb     = email.emailAlreadyOnDb();

    if (!tooBig 
        && isValid == Yes.IsValidEmail
        && localReceivers.length 
        && alreadyOnDb == No.AlreadyOnDb)
    {
        try
        {
            auto emailId = email.store();
            foreach(ref destination; localReceivers)
                processEmailForAddress(destination, email, emailId);
        } catch (Exception e)
        {
            string exceptionReport = "Email failed to save on DB because of exception:\n" ~ 
                                     e.msg;
            auto f = File(saveRejectedEmail(email), "a");
            f.writeln(exceptionReport);
            logError(exceptionReport);
        }
    }
    else
        // XXX rebound the message using the output route
        saveAndLogRejectedEmail(email, isValid, tooBig, 
                                to!(string[])(localReceivers), 
                                alreadyOnDb);
    return 0; // return != 0 == Postfix rebound the message. Avoid
}



//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


version(maintest)
unittest 
{
}
