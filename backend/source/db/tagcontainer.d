module db.tagcontainer;

import std.string: toLower;
import std.algorithm: sort;

struct TagContainer
{
    private bool[string] m_tags;

    bool has(string tag) const { return m_tags.get(toLower(tag), false); } 
    bool has(string[] tags)  const
    {
        bool hasAll = true;
        foreach(tag; tags) 
        {
            if (!has(tag)) 
            {
                hasAll = false;
                break;
            }
        }
        return hasAll;
    }
    bool opIndex(string name) const { return has(name); } 

    void add(string tag) { m_tags[toLower(tag)] = true; }
    void add(const string[] tags) { foreach(tag; tags) add(tag); }

    void remove(string tag) { m_tags[toLower(tag)] = false; }
    void remove(const string[] tags) { foreach(tag; tags) remove(tag); }

    const string[] array() const
    {
        string[] res;
        foreach(key, value; m_tags)
            if (m_tags[key]) res ~= key;
        sort(res);
        return res;
    }

    uint length() const
    {
        uint res = 0;
        foreach(key, value; m_tags)
            if (m_tags[key]) res++;
        return res;
    }




}



//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(db_test)
version(unittest)
{
    import std.stdio;
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
