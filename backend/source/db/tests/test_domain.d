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
module db.tests.test_domain;


version(db_test)
version(db_usetestdb)
{
    import std.stdio;
    import db.domain;
    import db.test_support;

    version(MongoDriver)
    {
        unittest // hasDefaultUser
        {
            writeln("Testing DriverDomainMongo.hasDefaultUser");
            recreateTestDb();
            assert(Domain.hasDefaultUser("testdatabase.com"), "Domain.hasDefaultUser1");
            assert(!Domain.hasDefaultUser("anotherdomain.com"), "Domain.hasDefaultUser2");
        }
    }
}
