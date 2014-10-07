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
            writeln("Testing DriverUserMongo.get");
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
            writeln("Testing DriverUserMongo.getFromLoginName");
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
            writeln("Testing DriverUserMongo.getFromAddress");
            recreateTestDb();

            auto user = User.getFromAddress("noexistnoexist@bla.com");
            assert(user is null);

            user = User.getFromAddress("testuser@testdatabase.com");
            assert(user.loginName == "testuser");
            assert(user.addresses == ["testuser@testdatabase.com"]);
            assert(user.admin);
            assert(user.loginHash == "[SHA512]d93TpULlMP0Ee4l3xle6bOcvFJLjYLKyISzSZOdewDg="~
                                     "$Gmb1QStQ3m0ArHT3t86BE7286+/w5WJ+gCwD/7+atFoyBhBpqtc"~
                                     "j2rh7XUDsX6Dw4rr1iPX6QTomfds5IZF3Dg==");
            assert(user.name == "testUserName");
            assert(user.surname == "testUserSurName");
        }
    }
}
