module db.envelope;

import std.string: format;
import std.conv: to;
import vibe.data.bson;
import db.mongo;
import db.email;

// An IncomingEmail object represents an email, but it can go to different users
// managed by this system, so an envelope has the same (unique) email plus the
// receiving address and a part that can change by every user.  It has a similar
// document structure on the DB.

class Envelope
{
    Email email;
    string destination;
    string userId;
    string emailId;
    string[] forwardTo;
    string dbId;

    this(Email email, string destination)
    {
        this.email       = email;
        this.destination = destination;
    }
    this(Email email, string destination, string userId, string emailId)
    {
        this(email, destination);
        this.userId      = userId;
        this.emailId     = emailId;
    }

    string toJson()
    {
        return format(`
            {
                "_id": "%s",
                "emailId": "%s",
                "userId": "%s",
                "destinationAddress": "%s",
                "forwardTo": %s
            }`,
            dbId, emailId, userId, destination, to!string(forwardTo)
        );
    }

    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================

    void store()
    {
        this.dbId = BsonObjectID.generate().toString;
        collection("envelope").insert(parseJsonString(this.toJson));
    }


}

//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


version(db_test)
version(db_usetestdb)
{
    import db.test_support;
    import std.stdio;
    import std.algorithm;
    import std.range;
    import vibe.db.mongo.mongo;

    unittest // envelope.store()
    {
        writeln("Testing Envelope.store");
        import std.exception;
        import core.exception;
        recreateTestDb();
        auto cursor = collection("envelope").find(
               ["destinationAddress": "testuser@testdatabase.com"]
        );
        assert(!cursor.empty);
        auto envDoc = cursor.front;
        cursor.popFrontExactly(2);
        assert(cursor.empty);
        assert(collectException!AssertError(cursor.popFront));
        assert(envDoc.forwardTo.type == Bson.Type.array);
        auto userId = getUserIdFromAddress("testuser@testdatabase.com");
        assert(bsonStr(envDoc.userId) == userId);
        auto emailId = Email.messageIdToDbId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(bsonStr(envDoc.emailId) == emailId);
    }
}
