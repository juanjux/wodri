module db.test_support;

import db.config;
import db.email;
import retriever.incomingemail;
import std.digest.md;
import std.file;
import std.path;
import std.process;
import std.string;
import std.typecons;

version(MongoDriver)
{
    import db.mongo.mongo;
    import vibe.db.mongo.mongo;
}

version(db_usetestdb)     version = anytestdb;
version(db_usebigdb)      version = anytestdb;
version(db_insertalltest) version = anytestdb;
version(db_insertalltest) version = db_usebigdb;
version(search_test)      version = db_usebigdb;


version(anytestdb)
{
    string[string] USER_TO_ID;

    immutable (string[]) TEST_EMAILS = ["multipart_mixed_rel_alternative_attachments",
                                        "simple_alternative_noattach",
                                        "spam_tagged",
                                        "with_2megs_attachment",
                                        "spam_notagged_nomsgid"];
    version(MongoDriver)
    {
        void emptyTestDb()
        {
            foreach(string coll; ["conversation", "emailIndexContents",
                                  "email", "domain", "user", "userrule"])
                collection(coll).remove();
            system(format("rm -f %s/*", getConfig.absAttachmentStore));
            system(format("rm -f %s/*", getConfig.absRawEmailStore));
        }

        void recreateTestDb()
        {
            import db.conversation;
            import db.user;
            import db.email;
            emptyTestDb();

            // Fill the test DB
            string backendTestDataDir_ = buildPath(getConfig().mainDir, "backend",
                                                   "test", "testdb");
            string[string] jsonfile2collection = ["user1.json"     : "user",
                                                  "user2.json"     : "user",
                                                  "domain1.json"   : "domain",
                                                  "domain2.json"   : "domain",
                                                  "userrule1.json" : "userrule",
                                                  "userrule2.json" : "userrule",];

            foreach(file_, coll; jsonfile2collection)
            {
                auto fixture = readText(buildPath(backendTestDataDir_, file_));
                collection(coll).insert(parseJsonString(fixture));
            }

            string backendTestEmailsDir = buildPath(
                    getConfig().mainDir, "backend", "test", "testemails"
            );

            foreach(mailname; TEST_EMAILS)
            {
                auto inEmail = new IncomingEmail();
                inEmail.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                                     getConfig.absAttachmentStore,
                                     getConfig.absRawEmailStore);

                auto destination = inEmail.getHeader("to").addresses[0];
                auto user = User.getFromAddress(destination);
                assert(user !is null);
                auto dbEmail = new Email(inEmail, destination);
                assert(dbEmail.isValid);
                dbEmail.store();
                Conversation.addEmail(dbEmail, ["inbox"], []);
            }

            // load the tests userIds
            auto usersCursor = collection("user").find();
            foreach(user; usersCursor)
            {
                USER_TO_ID[bsonStr(user.loginName)] = bsonStr(user._id);
            }
        }
    }
}

void assertEmailsEqual(Email dbEmail1,
                       Email dbEmail2,
                       Flag!"CompareBody" comparebody = Yes.CompareBody)
{
    assert(dbEmail1.messageId                 == dbEmail2.messageId);
    assert(strip(dbEmail1.from.rawValue)      == strip(dbEmail2.from.rawValue));
    assert(dbEmail1.from.addresses            == dbEmail2.from.addresses);
    assert(dbEmail1.receivers.addresses       == dbEmail2.receivers.addresses);
    assert(strip(dbEmail1.receivers.rawValue) == strip(dbEmail2.receivers.rawValue));

    foreach(name, value; dbEmail1.headers)
    {
        if (among(name, "Content-Type", "Received", "DKIM-Signature", "Received-SPF",
                  "DomainKey-Signature", "Return-Path", "Authentication-Results",
                  "X-Forwarded-To", "X-Forwarded-For"))
        {
            // boundary is going to be different or multiple headers if this type
            // FIXME: compare multiheaders too
            continue;
        }

        auto value2 = dbEmail2.getHeader(name);
        assert(strip(value.rawValue) == strip(value2.rawValue));
        assert(value.addresses       == value2.addresses);
    }

    foreach(idx, ref attach1; dbEmail1.attachments.list)
    {
        auto attach2 = dbEmail2.attachments.list()[idx];
        assert(attach1.ctype     == attach2.ctype);
        assert(attach1.filename  == attach2.filename);
        assert(attach1.contentId == attach2.contentId);
        assert(attach1.size      == attach2.size);

        assert(md5Of(std.file.read(attach1.realPath)) ==
               md5Of(std.file.read(attach2.realPath)));
    }

    if (comparebody)
    {
        foreach(idx, ref textp; dbEmail1.textParts)
        {
            assert(strip(textp.content) == strip(dbEmail2.textParts[idx].content));
        }
    }
}

// Insert everthing in the allmail directory into the DB, also, export as RFC in a temp file
version(db_insertalltest)
{
    unittest
    {
        import std.stdio;
        import db.conversation;
        import db.email;
        import std.datetime;
        import std.process;
        import retriever.incomingemail;

        writeln("Testing Inserting Everything");
        recreateTestDb();

        string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
        string origEmailDir    = buildPath(backendTestDir, "emails", "single_emails");
        string rawEmailStore   = buildPath(backendTestDir, "rawemails");
        string attachmentStore = buildPath(backendTestDir, "attachments");
        string invalidLogPath  = buildPath(backendTestDir, "invalid_mails.log");

        int[string] brokenEmails;
        StopWatch sw;
        StopWatch totalSw;
        ulong totalTime = 0;
        ulong count     = 0;
        auto invalidLog = File(invalidLogPath, "w");

        foreach (ref DirEntry e; getSortedEmailFilesList(origEmailDir))
        {
            //if (indexOf(e, "10072") == -1) continue; // For testing a specific email
            // if (to!int(e.name.baseName) < 29790) continue; // For testing from some email forward
            writeln(e.name, "...");

            if (baseName(e.name) in brokenEmails)
                continue;

            totalSw.start();
            auto inEmail = new IncomingEmail();

            sw.start();
            inEmail.loadFromFile(File(e.name), attachmentStore);
            sw.stop(); writeln("loadFromFile time: ", sw.peek().msecs); sw.reset();

            sw.start();
            auto dbEmail = new Email(inEmail);
            sw.stop(); writeln("DBEmail instance: ", sw.peek().msecs); sw.reset();

            if (dbEmail.isValid)
            {
                writeln("Subject: ", dbEmail.getHeader("subject").rawValue);

                sw.start();
                auto localReceivers = dbEmail.localReceivers();
                if (!localReceivers.length)
                {
                    writeln("SKIPPING, not local receivers");
                    totalSw.stop();
                    totalSw.reset();
                    continue; // probably a message from the "sent" folder
                }
                sw.stop(); writeln("localReceivers(): ", sw.peek().msecs); sw.reset();

                sw.start();
                dbEmail.setOwner(localReceivers[0]);
                dbEmail.store();
                sw.stop(); writeln("dbEmail.store(): ", sw.peek().msecs); sw.reset();

                sw.start();
                auto convId = Conversation.addEmail(dbEmail, ["inbox"], []).id;

                sw.stop(); writeln("Conversation: ", convId, " time: ", sw.peek().msecs); sw.reset();

                totalSw.stop();
                auto emailTime = totalSw.peek().msecs;
                totalTime += emailTime;
                ++count;
                writeln("Total time for inserting this email: ", emailTime);

                // check that a email exported with toRFC is parsed with and IncomingEmail
                // into basically the same email
                sw.start();
                auto dbEmail2 = Email.get(dbEmail.id);
                sw.stop(); writeln("Email.get time: ", sw.peek().msecs); sw.reset();
                sw.start();
                auto rfcString = dbEmail2.toRFCEmail();
                sw.stop(); writeln("Email.toRFCEmail time: ", sw.peek().msecs); sw.reset();

                // write to a temporal file for re-parsing
                string tmpFilePath = buildPath(getConfig().absRawEmailStore, "testfile.email");
                auto f = File(tmpFilePath, "w");
                f.write(rfcString); f.flush(); f.close();
                auto inEmail2 = new IncomingEmail();
                inEmail2.loadFromFile(tmpFilePath, getConfig.absAttachmentStore);
                auto dbEmail3 = new Email(inEmail2);
                // assertEmailsEqual(dbEmail2, dbEmail3, No.CompareBody);

            }
            else
            {
                writeln("SKIPPING, invalid email");
                invalidLog.write("------------------");
                invalidLog.write(dbEmail.rawEmailPath ~ "\n");
            }

            totalSw.reset();
        }

        writeln("Total number of valid emails: ", count);
        writeln("Average time per valid email: ", totalTime/count);

        // Clean the attachment and rawEmail dirs
        system(format("rm -f %s/*", attachmentStore));
        system(format("rm -f %s/*", rawEmailStore));
    }
}
