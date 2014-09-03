module db.mongo.driverusermongo;


version(MongoDriver)
{
import db.dbinterface.driveruserinterface;
import db.mongo.mongo;
import db.user: User;
import vibe.data.bson;
import vibe.db.mongo.mongo;

final class DriverUserMongo : DriverUserInterface
{
    private User getObjectFromField(in string fieldName, in string fieldValue)
    {
        immutable userResult = collection("user").findOne([fieldName: fieldValue]);
        return userResult.isNull ? null : userDocToObject(userResult);
    }


    private User userDocToObject(const ref Bson userDoc)
    {
        auto ret = new User();
        if (userDoc.isNull)
            return ret;

        ret.id = bsonStr(userDoc._id);
        ret.loginName = bsonStr(userDoc.loginName);
        ret.addresses = bsonStrArray(userDoc.addresses);
        ret.admin = bsonBool(userDoc.admin);
        ret.loginHash = bsonStr(userDoc.loginHash);
        ret.name = bsonStr(userDoc.name);
        ret.surname = bsonStr(userDoc.surname);
        return ret;
    }

//override: // buggy compiled doesnt detect the override
    User get(in string id)
    {
        return getObjectFromField("_id", id);
    }


    User getFromLoginName(in string login)
    {
        return getObjectFromField("loginName", login);
    }

    string getIdFromLoginName(in string login)
    {
        immutable userResult = collection("user").findOne(["loginName": login]);
        return userResult.isNull? "": bsonStrSafe(userResult._id);
    }


    User getFromAddress(in string address)
    {
        immutable userResult = collection("user").findOne(
                parseJsonString(`{"addresses": {"$in": [` ~ Json(address).toString ~ `]}}`)
        );
        return userResult.isNull ? null : userDocToObject(userResult);
    }
}
} // end version(MongoDriver)


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(db_test)
version(db_usetestdb)
{
    import std.stdio;
    import db.test_support;

    unittest // get
    {
        writeln("Testing User.get");
        recreateTestDb();
        auto userObject = User.get("doesntexits");
        assert(userObject is null);
        auto userDoc = collection("user").findOne(["loginName": "testuser"]);
        assert(!userDoc.isNull);
        userObject = User.get(bsonStr(userDoc._id));
        assert(userObject !is null);
        assert(bsonStr(userDoc._id) == userObject.id);
    }

    unittest // getFromLoginName
    {
        writeln("Testing User.getFromLoginName");
        recreateTestDb();
        auto userObject = User.getFromLoginName("doesntexists");
        assert(userObject is null);
        userObject = User.getFromLoginName("testuser");
        assert(userObject !is null);
        auto userDoc = collection("user").findOne(["loginName": "testuser"]);
        assert(!userDoc.isNull);
        assert(bsonStr(userDoc._id) == userObject.id);
    }

    unittest // getFromAddress + userDocToObject
    {
        writeln("Testing User.getFromAddress");
        recreateTestDb();

        auto user = User.getFromAddress("noexistnoexist@bla.com");
        assert(user is null);

        user = User.getFromAddress("testuser@testdatabase.com");
        assert(user.loginName == "testuser");
        assert(user.addresses == ["testuser@testdatabase.com"]);
        assert(user.admin);
        assert(user.loginHash == "8AQl5bqZMY3vbczoBWJiTFVclKU=");
        assert(user.name == "testUserName");
        assert(user.surname == "testUserSurName");
    }
}
