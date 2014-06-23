db.user.find().forEach(function(user) {
    print(tojson(user));
});
