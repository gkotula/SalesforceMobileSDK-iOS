/*
 Copyright (c) 2015, salesforce.com, inc. All rights reserved.
 
 Redistribution and use of this software in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of
 conditions and the following disclaimer in the documentation and/or other materials provided
 with the distribution.
 * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
 endorse or promote products derived from this software without specific prior written
 permission of salesforce.com, inc.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SFSmartStoreAlterTests.h"
#import "SFAlterSoupLongOperation.h"
#import "SFSmartStore+Internal.h"
#import "SFSoupIndex.h"
#import "SFQuerySpec.h"
#import "SFJsonUtils.h"
#import "FMDatabaseQueue.h"
#import "FMDatabase.h"

@interface SFSmartStoreAlterTests ()

@property (nonatomic, strong) SFUserAccount *smartStoreUser;
@property (nonatomic, strong) SFSmartStore *store;
@property (nonatomic, strong) SFSmartStore *globalStore;

@end

@implementation SFSmartStoreAlterTests

#define kTestSmartStoreName   @"testSmartStore"
#define kTestSoupName         @"testSoup"


#pragma mark - setup and teardown


- (void) setUp
{
    [super setUp];
    [SFLogger setLogLevel:SFLogLevelDebug];
    self.smartStoreUser = [self setUpSmartStoreUser];
    self.store = [SFSmartStore sharedStoreWithName:kTestSmartStoreName];
    self.globalStore = [SFSmartStore sharedGlobalStoreWithName:kTestSmartStoreName];
}

- (void) tearDown
{
    [SFSmartStore removeSharedStoreWithName:kTestSmartStoreName];
    [SFSmartStore removeSharedGlobalStoreWithName:kTestSmartStoreName];
    [self tearDownSmartStoreUser:self.smartStoreUser];
    [super tearDown];
    
    self.smartStoreUser = nil;
    self.store = nil;
    self.globalStore = nil;
}

#pragma mark - tests

-(void) testAlterSoupResumeAfterRenameOldSoupTable
{
    [self tryAlterSoupInterruptResume:SFAlterSoupStepRenameOldSoupTable];
}

-(void) testAlterSoupResumeAfterDropOldIndexes
{
    [self tryAlterSoupInterruptResume:SFAlterSoupStepDropOldIndexes];
}

-(void) testAlterSoupResumeAfterRegisterSoupUsingTableName
{
    [self tryAlterSoupInterruptResume:SFAlterSoupStepRegisterSoupUsingTableName];
}

-(void) testAlterSoupResumeAfterCopyTable
{
    [self tryAlterSoupInterruptResume:SFAlterSoupStepCopyTable];
}

-(void) testAlterSoupResumeAfterReIndexSoup
{
    [self tryAlterSoupInterruptResume:SFAlterSoupStepReIndexSoup];
}

-(void) testAlterSoupResumeAfterDropOldTable
{
    [self tryAlterSoupInterruptResume:SFAlterSoupStepDropOldTable];
}

#pragma mark - helper methods

- (void) tryAlterSoupInterruptResume:(SFAlterSoupStep)toStep
{
    for (SFSmartStore *store in @[ self.store, self.globalStore ]) {
        // Before
        XCTAssertFalse([store soupExists:kTestSoupName], @"Soup %@ should not exist", kTestSoupName);
        
        // Register
        NSDictionary* lastNameSoupIndex = @{@"path": @"lastName",@"type": @"string"};
        NSArray* indexSpecs = [SFSoupIndex asArraySoupIndexes:@[lastNameSoupIndex]];
        [store registerSoup:kTestSoupName withIndexSpecs:indexSpecs];
        BOOL testSoupExists = [store soupExists:kTestSoupName];
        XCTAssertTrue(testSoupExists, @"Soup %@ should exist", kTestSoupName);
        __block NSString* soupTableName;
        [store.storeQueue inDatabase:^(FMDatabase *db) {
            soupTableName = [store tableNameForSoup:kTestSoupName withDb:db];
        }];
        
        // Populate soup
        NSArray* entries = [SFJsonUtils objectFromJSONString:@"[{\"lastName\":\"Doe\", \"address\":{\"city\":\"San Francisco\",\"street\":\"1 market\"}},"
                            "{\"lastName\":\"Jackson\", \"address\":{\"city\":\"Los Angeles\",\"street\":\"100 mission\"}}]"];
        NSArray* insertedEntries  =[store upsertEntries:entries toSoup:kTestSoupName];
        
        // Partial alter - up to toStep included
        NSDictionary* citySoupIndex = @{@"path": @"address.city",@"type": @"string"};
        NSDictionary* streetSoupIndex = @{@"path": @"address.street",@"type": @"string"};
        NSArray* indexSpecsNew = [SFSoupIndex asArraySoupIndexes:@[lastNameSoupIndex, citySoupIndex, streetSoupIndex]];
        SFAlterSoupLongOperation* operation = [[SFAlterSoupLongOperation alloc] initWithStore:store soupName:kTestSoupName newIndexSpecs:indexSpecsNew reIndexData:YES];
        [operation runToStep:toStep];
        
        // Validate long_operations_status table
        NSArray* operations = [store getLongOperations];
        NSInteger expectedCount = (toStep == kLastStep ? 0 : 1);
        XCTAssertTrue([operations count] == expectedCount, @"Wrong number of long operations found");
        if ([operations count] > 0) {
            // Check details
            SFAlterSoupLongOperation* actualOperation = (SFAlterSoupLongOperation*)operations[0];
            XCTAssertEqualObjects(actualOperation.soupName, kTestSoupName, @"Wrong soup name");
            XCTAssertEqualObjects(actualOperation.soupTableName, soupTableName, @"Wrong soup name");
            XCTAssertTrue(actualOperation.reIndexData, @"Wrong re-index data");
            
            // Check last step completed
            XCTAssertEqual(actualOperation.afterStep, toStep, @"Wrong step");
            
            // Simulate restart (clear cache and call resumeLongOperations)
            // TODO clear memory cache
            [store resumeLongOperations];
            
            // Check that long operations table is now empty
            XCTAssertTrue([[store getLongOperations] count] == 0, @"There should be no long operations left");
            
            // Check index specs
            NSArray* actualIndexSpecs = [store indicesForSoup:kTestSoupName];
            [self checkIndexSpecs:actualIndexSpecs withExpectedIndexSpecs:[SFSoupIndex asArraySoupIndexes:indexSpecsNew] checkColumnName:NO];
            
            // Check data
            [store.storeQueue inDatabase:^(FMDatabase *db) {
                FMResultSet* frs = [store queryTable:soupTableName forColumns:nil orderBy:@"id ASC" limit:nil whereClause:nil whereArgs:nil withDb:db];
                [self checkSoupRow:frs withExpectedEntry:insertedEntries[0] withSoupIndexes:actualIndexSpecs];
                [self checkSoupRow:frs withExpectedEntry:insertedEntries[1] withSoupIndexes:actualIndexSpecs];
                XCTAssertFalse([frs next], @"Only two rows should have been returned");
                [frs close];
            }];
        }
    }
}

- (void) checkIndexSpecs:(NSArray*)actualSoupIndexes withExpectedIndexSpecs:(NSArray*)expectedSoupIndexes checkColumnName:(BOOL)checkColumnName
{
    XCTAssertTrue([actualSoupIndexes count] == [expectedSoupIndexes count], @"Wrong number of index specs");
    for (int i = 0; i<[expectedSoupIndexes count]; i++) {
        SFSoupIndex* actualSoupIndex = ((SFSoupIndex*)actualSoupIndexes[i]);
        SFSoupIndex* expectedSoupIndex = ((SFSoupIndex*)expectedSoupIndexes[i]);
        XCTAssertEqualObjects(actualSoupIndex.path, expectedSoupIndex.path, @"Wrong path");
        XCTAssertEqualObjects(actualSoupIndex.indexType, expectedSoupIndex.indexType, @"Wrong type");
        if (checkColumnName) {
            XCTAssertEqualObjects(actualSoupIndex.columnName, expectedSoupIndex.columnName, @"Wrong column name");
        }
    }
}

@end
