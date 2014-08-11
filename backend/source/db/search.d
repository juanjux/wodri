module db.search;

import db.mongo;
import std.stdio;
import std.algorithm;
import std.string;
import vibe.db.mongo.mongo;
import vibe.data.bson;

static shared immutable SEARCH_FIELDS = ["to", "subject", "cc", "bcc"];


string[] searchHeaders(string needle, string dateStart="", string dateEnd="")
{
    string[] res;
    void getMatchingIds(string where)
    {
        auto json = format(`{"%s":`~
                `{"$elemMatch": {"rawValue":`~
                `{"$regex": "%s",`~
                `"$options": "i"}}}}`, where, needle);
        auto bson = parseJsonString(json);
        auto emailIdsCur = collection("email").find(bson, ["_id": 1], QueryFlags.None);
        foreach(item; emailIdsCur)
            res ~= bsonStr(item._id);
    }

    getMatchingIds("from");
    foreach(ref field; SEARCH_FIELDS)
        getMatchingIds(format("headers.%s", field));

    sort(res);
    return uniq(res).array;
}


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|
version(search_test)
{
    import db.test_support;
    import std.datetime: StopWatch;

    unittest
    {
        write("Testing searchHeaders: ");

        //recreateTestDb();
        StopWatch sw;
        sw.start();
        auto ids = searchHeaders("test", "", "");
        sw.stop();
        writeln(ids);
        writeln("Total time for search: ", sw.peek().msecs);
    }
}
