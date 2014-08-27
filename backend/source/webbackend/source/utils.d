module webbackend.utils;

import db.config: getConfig;
import db.user: User;
import vibe.crypto.passwordhash;
import vibe.http.server;
import std.functional: toDelegate;


bool checkAuth(string user, string password)
{
    const dbUser = User.getFromLoginName(user);
    return dbUser is null ? false
                          : testSimplePasswordHash(dbUser.loginHash,
                                                   password,
                                                   getConfig.salt);
}
