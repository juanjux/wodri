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
module db.tests.test_tagcontainer;


version(db_test)
version(unittest)
{
    import std.stdio;
    import db.tagcontainer;
    unittest
    {
        writeln("Testing TagContainer.add/has");
        TagContainer t;
        t.add("polompos");
        assert(t.array == ["polompos"]);
        t.add("polompos");
        assert(t.array == ["polompos"]);
        t.add(["one", "two", "TWo", "two", "three"]);
        assert(t.length == 4);
        assert(t.has("one"));
        assert(t.has("oNe"));
        assert(t.has("two"));
        assert(t.has("three"));
        assert(t.has("polompos"));
        assert(t.has("POLOMPOS"));
        assert(t.has(["one", "two"]));
        assert(!t.has(["one", "two", "nope"]));
    }


    unittest
    {
        writeln("Testing TagContainer.remove");
        TagContainer t;
        t.remove("nothing");
        assert(t.array == []);
        t.add(["one", "two", "two", "TWO", "three"]);
    }


    unittest
    {
        writeln("Testing TagContainer.length");
        TagContainer t;
        assert(t.length == 0);
        t.add("polompos");
        assert(t.length == 1);
        t.add(["pok", "cogorcios"]);
        assert(t.length == 3);
        t.remove("nohas");
        assert(t.length == 3);
        t.remove(["pok", "cogorcios"]);
        assert(t.length == 1);
    }
}
