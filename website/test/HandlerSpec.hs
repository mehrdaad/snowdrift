module HandlerSpec (spec) where

import TestImport

import Network.Wai.Test (SResponse(..))

spec :: Spec
spec = withApp $ do
    describe "getRobotsR" $ do
        it "gives a 200" $ do
            get RobotsR
            statusIs 200
        it "has correct User-agent" $ do
            get RobotsR
            bodyContains "User-agent: *"
    describe "getFaviconR" $ do
        it "gives a 200" $ do
            get FaviconR
            statusIs 200
    describe "getWelcomeR" $ do
        describe "browsing anonymously" $ do
            it "loads" $ do
                get WelcomeR
                statusIs 200
            it "has a link to /how-it-works" $ do
                get WelcomeR
                htmlHasLink HowItWorksR
        describe "browsing while logged in" $ do
            it "loads" $ do
                dummyLogin
                printBody
                get WelcomeR
                statusIs 200
    describe "getDashboardR" $ do
        it "requires login" $
            needsAuth DashboardR "GET"

assertEqualContents :: SResponse -> SResponse -> YesodExample site ()
assertEqualContents = assertEqualOn simpleBody "Contents differ"

assertEqualOn :: (Show a, Eq a) => (t -> a) -> String -> t -> t -> YesodExample site ()
assertEqualOn f msg a b =
    assertEq msg (f a) (f b)
