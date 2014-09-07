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
