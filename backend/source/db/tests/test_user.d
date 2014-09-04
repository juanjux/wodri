module db.tests.test_user;

version(db_test)
version(db_usetestdb)
{
    import std.stdio;
    import db.test_support;
    import db.user;

    unittest // User.addressIsLocal
    {
        writeln("Testing User.addressIsLocal");
        recreateTestDb();
        assert(User.addressIsLocal("testuser@testdatabase.com"));
        assert(User.addressIsLocal("random@testdatabase.com")); // has default user
        assert(User.addressIsLocal("anotherUser@testdatabase.com"));
        assert(User.addressIsLocal("anotherUser@anotherdomain.com"));
        assert(!User.addressIsLocal("random@anotherdomain.com"));
    }

    version(MongoDriver)
    {
        import db.mongo.mongo;

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
}
