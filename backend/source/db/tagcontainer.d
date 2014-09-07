module db.tagcontainer;

import std.string: toLower;
import std.algorithm: sort;

struct TagContainer
{
    private bool[string] m_tags;

    bool has(in string tag) const
    {
        return m_tags.get(toLower(tag), false);
    }

    bool has(in string[] tags) const
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

    bool opIndex(in string name) const
    {
        return has(name);
    }

    void add(in string tag)
    {
        m_tags[toLower(tag)] = true;
    }

    void add(in string[] tags)
    {
        foreach(tag; tags) add(tag);
    }

    void remove(in string tag)
    {
        m_tags[toLower(tag)] = false;
    }

    void remove(in string[] tags)
    {
        foreach(tag; tags) remove(tag);
    }

    string[] array() const
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
            if (m_tags[key]) ++res;
        return res;
    }
}
