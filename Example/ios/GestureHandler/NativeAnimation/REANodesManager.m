#import "REANodesManager.h"

#import <React/RCTConvert.h>

#import "Nodes/REANode.h"
#import "Nodes/REAPropsNode.h"
#import "Nodes/REAStyleNode.h"
#import "Nodes/REATransformNode.h"
#import "Nodes/REAValueNode.h"
#import "Nodes/REABlockNode.h"
#import "Nodes/REACondNode.h"
#import "Nodes/REAOperatorNode.h"
#import "Nodes/REASetNode.h"
#import "Nodes/READebugNode.h"
#import "Nodes/REAClockNodes.h"
#import "Nodes/REAJSCallNode.h"
#import "Nodes/REABezierNode.h"
#import "Nodes/REAEventNode.h"

@implementation REANodesManager
{
  NSMutableDictionary<REANodeID, REANode *> *_nodes;
  NSMapTable<NSString *, REANode *> *_eventMapping;
  NSMutableArray<id<RCTEvent>> *_eventQueue;
  CADisplayLink *_displayLink;
  NSMutableArray<REAAfterAnimationCallback> *_afterAnimationCallbacks;
  NSMutableArray<REAOnAnimationCallback> *_onAnimationCallbacks;
}

- (instancetype)initWithModule:(REAModule *)reanimatedModule
                     uiManager:(RCTUIManager *)uiManager
{
  if ((self = [super init])) {
    _reanimatedModule = reanimatedModule;
    _uiManager = uiManager;
    _nodes = [NSMutableDictionary new];
    _eventMapping = [NSMapTable strongToWeakObjectsMapTable];
    _eventQueue = [NSMutableArray new];
    _onAnimationCallbacks = [NSMutableArray new];
    _afterAnimationCallbacks = [NSMutableArray new];
  }
  return self;
}

- (void)invalidate
{
  [self stopUpdatingOnAnimationFrame];
}

- (REANode *)findNodeByID:(REANodeID)nodeID
{
  return _nodes[nodeID];
}

- (void)postOnAnimation:(REAOnAnimationCallback)clb
{
  [_onAnimationCallbacks addObject:clb];
}

- (void)postAfterAnimation:(REAAfterAnimationCallback)clb
{
  [_afterAnimationCallbacks addObject:clb];
  [self startUpdatingOnAnimationFrame];
}

- (void)startUpdatingOnAnimationFrame
{
  if (!_displayLink) {
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onAnimationFrame:)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
  }
}

- (void)stopUpdatingOnAnimationFrame
{
  if (_displayLink) {
    [_displayLink invalidate];
    _displayLink = nil;
  }
}

- (void)onAnimationFrame:(CADisplayLink *)displayLink
{
  // We process all enqueued events first
  for (NSUInteger i = 0; i < _eventQueue.count; i++) {
    id<RCTEvent> event = _eventQueue[i];
    [self processEvent:event];
  }
  [_eventQueue removeAllObjects];

  NSArray<REAOnAnimationCallback> *callbacks = _onAnimationCallbacks;
  _onAnimationCallbacks = [NSMutableArray new];

  // When one of the callbacks would postOnAnimation callback we don't want
  // to process it until the next frame. This is why we cpy the array before
  // we iterate over it
  for (REAOnAnimationCallback block in callbacks) {
    block(displayLink);
  }

  // new items can be added to the _afterAnimationCallback array during the
  // loop by the enqueued callbacks. In that case we want to run them immediately
  // and clear after animation queue once all the callbacks are done
  for (NSUInteger i = 0; i < _afterAnimationCallbacks.count; i++) {
    _afterAnimationCallbacks[i]();
  }
  [_afterAnimationCallbacks removeAllObjects];

  if (_onAnimationCallbacks.count == 0) {
    [self stopUpdatingOnAnimationFrame];
  }
}

#pragma mark -- Graph

- (void)createNode:(REANodeID)nodeID
            config:(NSDictionary<NSString *, id> *)config
{
  static NSDictionary *map;
  static dispatch_once_t mapToken;
  dispatch_once(&mapToken, ^{
    map = @{@"props": [REAPropsNode class],
            @"style": [REAStyleNode class],
            @"transform": [REATransformNode class],
            @"value": [REAValueNode class],
            @"block": [REABlockNode class],
            @"cond": [REACondNode class],
            @"op": [REAOperatorNode class],
            @"set": [REASetNode class],
            @"debug": [READebugNode class],
            @"clock": [REAClockNode class],
            @"clockStart": [REAClockStartNode class],
            @"clockStop": [REAClockStopNode class],
            @"clockTest": [REAClockTestNode class],
            @"call": [REAJSCallNode class],
            @"bezier": [REABezierNode class],
            @"event": [REAEventNode class],
//            @"listener": nil,
            };
  });

  NSString *nodeType = [RCTConvert NSString:config[@"type"]];

  Class nodeClass = map[nodeType];
  if (!nodeClass) {
    RCTLogError(@"Animated node type %@ not supported natively", nodeType);
    return;
  }

  REANode *node = [[nodeClass alloc] initWithID:nodeID config:config];
  node.nodesManager = self;
  _nodes[nodeID] = node;
}

- (void)dropNode:(REANodeID)nodeID
{
  REANode *node = _nodes[nodeID];
  if (node) {
    [_nodes removeObjectForKey:nodeID];
  }
}

- (void)connectNodes:(nonnull NSNumber *)parentID childID:(nonnull REANodeID)childID
{
  RCTAssertParam(parentID);
  RCTAssertParam(childID);

  REANode *parentNode = _nodes[parentID];
  REANode *childNode = _nodes[childID];

  RCTAssertParam(parentNode);
  RCTAssertParam(childNode);

  [parentNode addChild:childNode];
}

- (void)disconnectNodes:(REANodeID)parentID childID:(REANodeID)childID
{
  RCTAssertParam(parentID);
  RCTAssertParam(childID);

  REANode *parentNode = _nodes[parentID];
  REANode *childNode = _nodes[childID];

  RCTAssertParam(parentNode);
  RCTAssertParam(childNode);

  [parentNode removeChild:childNode];
}

- (void)connectNodeToView:(REANodeID)nodeID
                  viewTag:(NSNumber *)viewTag
                 viewName:(NSString *)viewName
{
  RCTAssertParam(nodeID);
  REANode *node = _nodes[nodeID];
  RCTAssertParam(node);

  if ([node isKindOfClass:[REAPropsNode class]]) {
    [(REAPropsNode *)node connectToView:viewTag viewName:viewName];
  }
}

- (void)attachEvent:(NSNumber *)viewTag
          eventName:(NSString *)eventName
        eventNodeID:(REANodeID)eventNodeID
{
  RCTAssertParam(eventNodeID);
  REANode *eventNode = _nodes[eventNodeID];
  RCTAssert([eventNode isKindOfClass:[REAEventNode class]], @"Event node is of an invalid type");

  NSString *key = [NSString stringWithFormat:@"%@%@", viewTag, eventName];
  RCTAssert([_eventMapping objectForKey:key] == nil, @"Event handler already set for the given view and event type");
  [_eventMapping setObject:eventNode forKey:key];
}

- (void)detachEvent:(NSNumber *)viewTag
          eventName:(NSString *)eventName
        eventNodeID:(REANodeID)eventNodeID
{
  NSString *key = [NSString stringWithFormat:@"%@%@", viewTag, eventName];
  [_eventMapping removeObjectForKey:key];
}

- (void)processEvent:(id<RCTEvent>)event
{
  NSString *key = [NSString stringWithFormat:@"%@%@", event.viewTag, event.eventName];
  REAEventNode *eventNode = [_eventMapping objectForKey:key];
  [eventNode processEvent:event];
}

- (void)dispatchEvent:(id<RCTEvent>)event
{
  NSString *key = [NSString stringWithFormat:@"%@%@", event.viewTag, event.eventName];
  REANode *eventNode = [_eventMapping objectForKey:key];

  if (eventNode != nil) {
    // enqueue node to be processed
    [_eventQueue addObject:event];
    [self startUpdatingOnAnimationFrame];
  }
}

//- (void)disconnectAnimatedNodeFromView:(nonnull NSNumber *)nodeTag
//                               viewTag:(nonnull NSNumber *)viewTag
//{
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//  if ([node isKindOfClass:[RCTPropsAnimatedNode class]]) {
//    [(RCTPropsAnimatedNode *)node disconnectFromView:viewTag];
//  }
//}
//
//- (void)restoreDefaultValues:(nonnull NSNumber *)nodeTag
//{
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//  // Restoring default values needs to happen before UIManager operations so it is
//  // possible the node hasn't been created yet if it is being connected and
//  // disconnected in the same batch. In that case we don't need to restore
//  // default values since it will never actually update the view.
//  if (node == nil) {
//    return;
//  }
//  if (![node isKindOfClass:[RCTPropsAnimatedNode class]]) {
//    RCTLogError(@"Not a props node.");
//  }
//  [(RCTPropsAnimatedNode *)node restoreDefaultValues];
//}
//
//
//#pragma mark -- Mutations
//
//- (void)setAnimatedNodeValue:(nonnull NSNumber *)nodeTag
//                       value:(nonnull NSNumber *)value
//{
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//  if (![node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    RCTLogError(@"Not a value node.");
//    return;
//  }
//  [self stopAnimationsForNode:node];
//
//  RCTValueAnimatedNode *valueNode = (RCTValueAnimatedNode *)node;
//  valueNode.value = value.floatValue;
//  [valueNode setNeedsUpdate];
//}
//
//- (void)setAnimatedNodeOffset:(nonnull NSNumber *)nodeTag
//                       offset:(nonnull NSNumber *)offset
//{
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//  if (![node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    RCTLogError(@"Not a value node.");
//    return;
//  }
//
//  RCTValueAnimatedNode *valueNode = (RCTValueAnimatedNode *)node;
//  [valueNode setOffset:offset.floatValue];
//  [valueNode setNeedsUpdate];
//}
//
//- (void)flattenAnimatedNodeOffset:(nonnull NSNumber *)nodeTag
//{
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//  if (![node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    RCTLogError(@"Not a value node.");
//    return;
//  }
//
//  RCTValueAnimatedNode *valueNode = (RCTValueAnimatedNode *)node;
//  [valueNode flattenOffset];
//}
//
//- (void)extractAnimatedNodeOffset:(nonnull NSNumber *)nodeTag
//{
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//  if (![node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    RCTLogError(@"Not a value node.");
//    return;
//  }
//
//  RCTValueAnimatedNode *valueNode = (RCTValueAnimatedNode *)node;
//  [valueNode extractOffset];
//}
//
//#pragma mark -- Events
//
//- (void)addAnimatedEventToView:(nonnull NSNumber *)viewTag
//                     eventName:(nonnull NSString *)eventName
//                  eventMapping:(NSDictionary<NSString *, id> *)eventMapping
//{
//  NSNumber *nodeTag = [RCTConvert NSNumber:eventMapping[@"animatedValueTag"]];
//  REAReanimatedNode *node = _animationNodes[nodeTag];
//
//  if (!node) {
//    RCTLogError(@"Animated node with tag %@ does not exists", nodeTag);
//    return;
//  }
//
//  if (![node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    RCTLogError(@"Animated node connected to event should be of type RCTValueAnimatedNode");
//    return;
//  }
//
//  NSArray<NSString *> *eventPath = [RCTConvert NSStringArray:eventMapping[@"nativeEventPath"]];
//
//  RCTEventAnimation *driver =
//    [[RCTEventAnimation alloc] initWithEventPath:eventPath valueNode:(RCTValueAnimatedNode *)node];
//
//  NSString *key = [NSString stringWithFormat:@"%@%@", viewTag, eventName];
//  if (_eventDrivers[key] != nil) {
//    [_eventDrivers[key] addObject:driver];
//  } else {
//    NSMutableArray<RCTEventAnimation *> *drivers = [NSMutableArray new];
//    [drivers addObject:driver];
//    _eventDrivers[key] = drivers;
//  }
//}
//
//- (void)removeAnimatedEventFromView:(nonnull NSNumber *)viewTag
//                          eventName:(nonnull NSString *)eventName
//                    animatedNodeTag:(nonnull NSNumber *)animatedNodeTag
//{
//  NSString *key = [NSString stringWithFormat:@"%@%@", viewTag, eventName];
//  if (_eventDrivers[key] != nil) {
//    if (_eventDrivers[key].count == 1) {
//      [_eventDrivers removeObjectForKey:key];
//    } else {
//      NSMutableArray<RCTEventAnimation *> *driversForKey = _eventDrivers[key];
//      for (NSUInteger i = 0; i < driversForKey.count; i++) {
//        if (driversForKey[i].valueNode.nodeTag == animatedNodeTag) {
//          [driversForKey removeObjectAtIndex:i];
//          break;
//        }
//      }
//    }
//  }
//}
//
//- (void)handleAnimatedEvent:(id<RCTEvent>)event
//{
//  if (_eventDrivers.count == 0) {
//    return;
//  }
//
//  NSString *key = [NSString stringWithFormat:@"%@%@", event.viewTag, event.eventName];
//  NSMutableArray<RCTEventAnimation *> *driversForKey = _eventDrivers[key];
//  if (driversForKey) {
//    for (RCTEventAnimation *driver in driversForKey) {
//      [self stopAnimationsForNode:driver.valueNode];
//      [driver updateWithEvent:event];
//    }
//
//    [self updateAnimations];
//  }
//}
//
//#pragma mark -- Listeners
//
//- (void)startListeningToAnimatedNodeValue:(nonnull NSNumber *)tag
//                            valueObserver:(id<RCTValueAnimatedNodeObserver>)valueObserver
//{
//  REAReanimatedNode *node = _animationNodes[tag];
//  if ([node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    ((RCTValueAnimatedNode *)node).valueObserver = valueObserver;
//  }
//}
//
//- (void)stopListeningToAnimatedNodeValue:(nonnull NSNumber *)tag
//{
//  REAReanimatedNode *node = _animationNodes[tag];
//  if ([node isKindOfClass:[RCTValueAnimatedNode class]]) {
//    ((RCTValueAnimatedNode *)node).valueObserver = nil;
//  }
//}
//
//
#pragma mark -- Animation Loop


@end
