module db.mongo.driveruserfiltermongo;


version(MongoDriver)
{
import db.dbinterface.driveruserfilterinterface;
import db.mongo.mongo;
import db.userfilter: UserFilter, Match, Action, SizeRuleType;
import vibe.data.bson;
import vibe.core.log;
import std.string;

final class DriverUserfilterMongo : DriverUserfilterInterface
{
// this override doesnt detect getByAddress as override if uncommented, probably compiler
// bug: FIXME: try with laters versions or open bug report:
//override:

    UserFilter[] getByAddress(in string address)
    {
        UserFilter[] res;
        const userRuleFindJson = parseJsonString(
                format(`{"destinationAccounts": {"$in": ["%s"]}}`, address)
        );
        auto userRuleCursor = collection("userrule").find(userRuleFindJson);

        foreach(ref Bson rule; userRuleCursor)
        {
            Match match;
            Action action;
            try
            {
                immutable sizeRule = bsonStr(rule.match_sizeRuleType);
                switch(sizeRule)
                {
                    case "None":
                        match.totalSizeType = SizeRuleType.None; break;
                    case "SmallerThan":
                        match.totalSizeType = SizeRuleType.SmallerThan; break;
                    case "GreaterThan":
                        match.totalSizeType = SizeRuleType.GreaterThan; break;
                    default:
                        auto err = "SizeRuleType must be one of None, GreaterThan or SmallerThan";
                        logError(err);
                        throw new Exception(err);
                }

                match.withAttachment = bsonBool    (rule.match_withAttachment);
                match.withHtml       = bsonBool    (rule.match_withHtml);
                match.totalSizeValue = to!ulong    (bsonNumber(rule.match_totalSizeValue));
                match.bodyMatches    = bsonStrArray(rule.match_bodyText);
                match.headerMatches  = bsonStrHash (rule.match_headers);

                action.noInbox       = bsonBool    (rule.action_noInbox);
                action.markAsRead    = bsonBool    (rule.action_markAsRead);
                action.deleteIt      = bsonBool    (rule.action_delete);
                action.neverSpam     = bsonBool    (rule.action_neverSpam);
                action.setSpam       = bsonBool    (rule.action_setSpam);
                action.forwardTo     = bsonStrArray(rule.action_forwardTo);
                action.addTags       = bsonStrArray(rule.action_addTags);

                res ~= new UserFilter(match, action);
            } catch (Exception e)
            logWarn("Error deserializing rule from DB, ignoring: %s: %s", rule, e);
        }
        return res;
    }
override:
}
} // end version(MongoDriver)


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


version(db_test)
version(db_usetestdb)
{

    import db.test_support;
    import std.stdio;
    unittest // getByAddress
    {
        writeln("Testing DriverUserFilterMongo.getByAddress");
        auto filters = UserFilter.getByAddress("testuser@testdatabase.com");
        assert(filters.length == 1);
        assert(!filters[0].match.withAttachment);
        assert(!filters[0].match.withHtml);
        assert(filters[0].match.totalSizeType        == SizeRuleType.GreaterThan);
        assert(filters[0].match.totalSizeValue       == 100485760);
        assert(filters[0].match.bodyMatches.length   == 1);
        assert(filters[0].match.bodyMatches[0]       == "XXXBODYMATCHXXX");
        assert(filters[0].match.headerMatches.length == 1);
        assert("From" in filters[0].match.headerMatches);
        assert(filters[0].match.headerMatches["From"] == "juanjo@juanjoalvarez.net");
        assert(!filters[0].action.forwardTo.length);
        assert(!filters[0].action.noInbox);
        assert(filters[0].action.markAsRead);
        assert(!filters[0].action.deleteIt);
        assert(filters[0].action.neverSpam);
        assert(!filters[0].action.setSpam);
        assert(filters[0].action.addTags == ["testtag1", "testtag2"]);
        auto filters2 = UserFilter.getByAddress("anotherUser@anotherdomain.com");
        assert(filters2[0].action.addTags == ["testtag3", "testtag4"]);
        auto newfilters = UserFilter.getByAddress("anotherUser@testdatabase.com");
        assert(filters2[0].action.addTags == newfilters[0].action.addTags);
    }
}
