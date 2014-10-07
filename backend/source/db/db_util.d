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
module db.db_util;

static this()
{
    // check that no more than one DB driver is selected
    version(MongoDriver)
    {
        version(SqliteDriver)
            static assert(0, "You must select only one DB driver");
        version(PostgreSQLDriver)
            static assert(0, "You must select only one DB driver");
    }

    version(SqliteDriver)
    {
        version(PostgreSQLDriver)
            static assert(0, "You must select only one DB driver");
    }
}
