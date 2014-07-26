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
import db.mongo;
import db.config;
import db.conversation;
import db.envelope;
import db.userfilter;
import db.email;
import db.user;

version(maintest){}
else version = not_maintest;


// XXX test when I've the full cicle tests
string saveRejectedEmail(Email email)
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
void saveAndLogRejectedEmail(Email email, 
                             Flag!"IsValidEmail" isValid, 
                             bool tooBig,
                             const string[] localReceivers, 
                             Flag!"EmailOnDb" alreadyOnDb)
{
    auto failedEmailPath = saveRejectedEmail(email);
    auto f = File(failedEmailPath, "a");
    f.writeln("\n\n===NOT DELIVERY BECAUSE OF===", 
                    isValid == !isValid? "\nInvalid headers":"",
                    !localReceivers.length? "\nInvalid destination":"",
                    tooBig? "\nMessage too big":"",
                    alreadyOnDb? "\nAlready on DB": "");

    logInfo(format("Message denied from SMTP. ValidHeaders:%s "~
                   "numLocalReceivers:%s SizeTooBig:%s. AlreadyOnDb: %s " ~
                   "Message copy stored at %s",
                   isValid, localReceivers.length, tooBig, alreadyOnDb, failedEmailPath));
}


// XXX test when I've the integration tests
void processEmailForAddress(string destination, Email email, string emailId)
{
    // Create the email=>user envelope
    auto user         = User.getFromAddress(destination);
    string userId     = user is null? "": user.id;
    auto envelope     = new Envelope(email, destination, userId);
    bool[string] tags = ["inbox": true];

    if (email.hasHeader("x-spam-setspamtag"))
        tags["spam"] = true;

    // Apply the user-defined filters (if any)
    const userFilters = UserFilter.getByAddress(destination);
    foreach(filter; userFilters)
        filter.apply(envelope, tags);

    envelope.store();
    Conversation.upsert(email, userId, tags);
}

// XXX test when I've the full cycle tests
version(not_maintest)
int main()
{
    const config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"), 
               LogLevel.info);

    auto inEmail = new IncomingEmailImpl();
    inEmail.loadFromFile(std.stdio.stdin, config.attachmentStore, config.rawEmailStore);

    auto dbEmail         = new Email(inEmail);
    bool tooBig          = (dbEmail.size() > config.incomingMessageLimit);
    auto isValid         = dbEmail.isValid();
    const localReceivers = uniq(dbEmail.localReceivers()).array;
    auto alreadyOnDb     = dbEmail.isOnDb();

    if (!tooBig 
        && isValid
        && localReceivers.length 
        && !alreadyOnDb)
    {
        try
        {
            auto emailId = dbEmail.store();
            foreach(ref destination; localReceivers)
                processEmailForAddress(destination, dbEmail, emailId);
        } catch (Exception e)
        {
            string exceptionReport = "Email failed to save on DB because of exception:\n" ~ 
                                     e.msg;
            auto f = File(saveRejectedEmail(dbEmail), "a");
            f.writeln(exceptionReport);
            logError(exceptionReport);
        }
    }
    else
        // XXX rebound the message using the output route
        saveAndLogRejectedEmail(dbEmail, isValid, tooBig, 
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
