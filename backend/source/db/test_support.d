module db.test_support;

import db.config;
import db.conversation;
import db.email;
import db.mongo;
import db.user;
import retriever.incomingemail;
import std.file;
import std.path;
import std.process;
import std.string;
import std.typecons;
import vibe.db.mongo.mongo;


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
            assert(dbEmail.isValid, "Email is not valid");
            auto emailId = Email.dbDriver.store(dbEmail);
            Conversation.upsert(dbEmail, ["inbox"], []);
        }

        // load the tests userIds
        auto usersCursor = collection("user").find();
        foreach(user; usersCursor)
        {
            USER_TO_ID[bsonStr(user.loginName)] = bsonStr(user._id);
        }
    }
}


version(db_insertalltest) 
{
    unittest
    {
        writeln("Testing Inserting Everything");
        recreateTestDb();

        import std.datetime;
        import std.process;
        import retriever.incomingemail;

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
            //if (to!int(e.name.baseName) < 10072) continue; // For testing from some email forward
            writeln(e.name, "...");

            if (baseName(e.name) in brokenEmails)
                continue;

            totalSw.start();
            auto inEmail = new IncomingEmailImpl();

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
                auto convId = Conversation.upsert(dbEmail, ["inbox"], []).dbId;

                sw.stop(); writeln("Conversation: ", convId, " time: ", sw.peek().msecs); sw.reset();

                totalSw.stop();
                auto emailTime = totalSw.peek().msecs;
                totalTime += emailTime;
                ++count;
                writeln("Total time for this email: ", emailTime);
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
