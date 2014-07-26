module db.test_support;

import std.string;
import std.path;
import std.file;
import vibe.db.mongo.mongo;
import db.email;
import db.conversation;
import db.mongo;
import db.config;
import db.envelope;
import db.user;
import retriever.incomingemail;

version(db_usetestdb)
{
    void emptyTestDb()
    {
        foreach(string coll; ["conversation", "envelope", "emailIndexContents", 
                              "email", "domain", "user", "userrule"])
            collection(coll).remove();
    }

    void recreateTestDb()
    {
        emptyTestDb();

        // Fill the test DB
        string backendTestDataDir_ = buildPath(getConfig().mainDir, "backend", "test", "testdb");
        string[string] jsonfile2collection = ["user1.json"     : "user",
                                              "user2.json"     : "user",
                                              "domain1.json"   : "domain",
                                              "domain2.json"   : "domain",
                                              "userrule1.json" : "userrule",
                                              "userrule2.json" : "userrule",];
        foreach(file_, coll; jsonfile2collection)
            collection(coll).insert(parseJsonString(readText(buildPath(backendTestDataDir_, file_))));

        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");
        foreach(mailname; TEST_EMAILS)
        {
            auto inEmail        = new IncomingEmailImpl();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                                 getConfig.absAttachmentStore,
                                 getConfig.absRawEmailStore);
            auto dbEmail      = new Email(inEmail);
            assert(dbEmail.isValid, "Email is not valid");
            auto destination  = dbEmail.getHeader("to").addresses[0];
            auto emailId      = dbEmail.store();
            auto user         = User.getFromAddress(destination);
            assert(user !is null);
            auto envelope     = new Envelope(dbEmail, destination, user.id);
            envelope.store();
            Conversation.upsert(dbEmail, user.id, ["inbox": true]);
        }
    }
}


version(db_insertalltest) unittest
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
    int[string] brokenEmails;
    StopWatch sw;
    StopWatch totalSw;
    ulong totalTime = 0;
    ulong count = 0;

    foreach (ref DirEntry e; getSortedEmailFilesList(origEmailDir))
    {
        //if (indexOf(e, "10072") == -1) continue; // For testing a specific email
        //if (to!int(e.name.baseName) < 10072) continue; // For testing from some email forward
        writeln(e.name, "...");

        totalSw.start();
        if (baseName(e.name) in brokenEmails)
            continue;
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
            dbEmail.store();
            sw.stop(); writeln("dbEmail.store(): ", sw.peek().msecs); sw.reset();

            sw.start();
            auto localReceivers = dbEmail.localReceivers();
            if (!localReceivers.length)
            {
                writeln("SKIPPING, not local receivers");
                continue; // probably a message from the "sent" folder
            }

            auto user = User.getFromAddress(localReceivers[0]);
            assert(user !is null);
            auto envelope = new Envelope(dbEmail, localReceivers[0], user.id);
            assert(envelope.user.id.length,
                    "Please replace the destination in the test emails, not: " ~
                    envelope.destination);
            sw.stop(); writeln("User.getFromAddress time: ", sw.peek().msecs); sw.reset();

            sw.start();
            envelope.store();
            sw.stop(); writeln("envelope.store(): ", sw.peek().msecs); sw.reset();

            sw.start();
            auto convId = Conversation.upsert(dbEmail, 
                                              envelope.user.id, 
                                              ["inbox": true]).dbId;

            sw.stop(); writeln("Conversation: ", convId, " time: ", sw.peek().msecs); sw.reset();
        }
        else
            writeln("SKIPPING, invalid email");

        totalSw.stop();
        if (dbEmail.isValid)
        {
            auto emailTime = totalSw.peek().msecs;
            totalTime += emailTime;
            ++count;
            writeln("Total time for this email: ", emailTime);
        }
        writeln("Valid emails until now: ", count); writeln;
        totalSw.reset();
    }

    writeln("Total number of valid emails: ", count);
    writeln("Average time per valid email: ", totalTime/count);

    // Clean the attachment and rawEmail dirs
    system(format("rm -f %s/*", attachmentStore));
    system(format("rm -f %s/*", rawEmailStore));
}


version(db_test)
version(db_usetestdb)
{
    unittest // domainHasDefaultUser
    {
        writeln("Testing domainHasDefaultUser");
        recreateTestDb();
        assert(domainHasDefaultUser("testdatabase.com"), "domainHasDefaultUser1");
        assert(!domainHasDefaultUser("anotherdomain.com"), "domainHasDefaultUser2");
    }
}
