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
