#!/usr/bin/env rdmd
/*
    Copyright (C) 2014-2015  Juan Jose Alvarez Martinez <juanjo@juanjoalvarez.net>

    This file is part of Wodri. Wodri is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License version 3 as published by the
    Free Software Foundation.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
    without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License along with this
    program. If not, see <http://www.gnu.org/licenses/>.
*/
module retriever.main;

import std.stdio;
import std.typecons;
import std.path;
import std.file;
import std.string;
import std.conv;
import std.algorithm: uniq, sort;
import std.array: array;
import vibe.core.log;
import retriever.incomingemail;
import db.config;
import db.conversation;
import db.userfilter;
import db.email;
import db.user;
version(MongoDriver)
{
    import db.mongo.mongo;
}

version(maintest){}
else version = not_maintest;


// XXX test when I've the full cicle tests
string saveRejectedEmail(in Email email)
{
    immutable config = getConfig();
    immutable failedEmailDir = buildPath(config.mainDir, "backend", "log", "failed_emails");
    if (!failedEmailDir.exists)
        mkdir(failedEmailDir);

    // Save a copy of the denied email in failedEmailPath and log the event
    immutable failedEmailPath = buildPath(failedEmailDir, baseName(email.rawEmailPath));
    copy(email.rawEmailPath, failedEmailPath);
    remove(email.rawEmailPath);
    return failedEmailPath;
}


// XXX test when I've the full cicle tests
void saveAndLogRejectedEmail(in Email email,
                             in Flag!"IsValidEmail" isValid,
                             in bool tooBig,
                             in string[] localReceivers)
{
    immutable failedEmailPath = saveRejectedEmail(email);
    auto f = File(failedEmailPath, "a");
    f.writeln("\n\n===NOT DELIVERY BECAUSE OF===",
                    isValid == !isValid? "\nInvalid headers":"",
                    !localReceivers.length? "\nInvalid destination":"",
                    tooBig? "\nMessage too big":"");

    logInfo(format("Message denied from SMTP. ValidHeaders:%s "~
                   "numLocalReceivers:%s SizeTooBig:%s. " ~
                   "Message copy stored at %s",
                   isValid, localReceivers.length, tooBig, failedEmailPath));
}


// XXX test when I've the integration tests
/** Store a new email in DB and addEmail a conversation every local receiver
 */
void processEmailForAddress(in string destination, Email email)
{
    email.setOwner(destination);
    email.store(Yes.ForceInsertNew);
    string[] tagsToAdd = ["inbox"];
    string[] tagsToRemove;

    if (email.hasHeader("x-spam-setspamtag"))
        tagsToAdd ~= "spam";

    // Apply the user-defined filters (if any)
    const userFilters = UserFilter.getByAddress(destination);
    foreach(filter; userFilters)
        filter.apply(email, tagsToAdd, tagsToRemove);

    Conversation.addEmail(email, tagsToAdd, tagsToRemove);
}

// XXX test when I've the full cycle tests
version(not_maintest)
int main()
{
    immutable config = getConfig();
    setLogFile(buildPath(config.mainDir, "backend", "log", "retriever.log"),
               LogLevel.info);

    auto inEmail = new IncomingEmail();
    inEmail.loadFromFile(std.stdio.stdin, config.attachmentStore, config.rawEmailStore);

    auto dbEmail          = new Email(inEmail);
    immutable bool tooBig = (dbEmail.size() > config.incomingMessageLimit);
    immutable isValid     = dbEmail.isValid();
    auto sortedReceivers  = dbEmail.localReceivers();
    sort(sortedReceivers);
    const localReceivers = uniq(sortedReceivers).array;

    if (!tooBig && isValid && localReceivers.length)
    {
        try
        {
            foreach(ref destination; localReceivers)
                processEmailForAddress(destination, dbEmail);
        } catch (Exception e)
        {
            immutable exceptionReport = "Email failed to save on DB because of exception:\n" ~
                                         e.msg;
            auto f = File(saveRejectedEmail(dbEmail), "a");
            f.writeln(exceptionReport);
            logError(exceptionReport);
        }
    }
    else
        // XXX rebound the message using the output route
        saveAndLogRejectedEmail(dbEmail, isValid, tooBig,
                                to!(string[])(localReceivers));
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
