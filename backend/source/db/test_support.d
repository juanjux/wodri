module db.test_support;

import std.string;
import std.path;
import std.file;
import vibe.db.mongo.mongo;
import db.email;
import db.conversation;
import db.mongo;
import db.envelope;
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
            assert(inEmail.isValid, "Email is not valid");
            auto dbEmail      = new Email(inEmail);
            auto destination  = dbEmail.getHeader("to").addresses[0];
            auto emailId      = dbEmail.store();
            auto userId       = getUserIdFromAddress(destination);
            auto envelope     = new Envelope(dbEmail, destination, userId, emailId);
            envelope.store();
            Conversation.upsert(dbEmail, userId, ["inbox": true]);
        }
    }
}
