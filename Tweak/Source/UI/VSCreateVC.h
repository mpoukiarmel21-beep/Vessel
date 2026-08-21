//  VSCreateVC.h — guided container creation (ARCHITECTURE §6, the 3 "steps").
//
//  Presented as a single scrolling form with three labelled sections rather than
//  a paged wizard: the content is the same (1 name + color, 2 the generated
//  identity shown in clear and regenerable, 3 an optional location), and one
//  screen has far less state to get wrong than three swiped panes. The identity
//  shown IS the one the container is created with — regenerating replaces it, so
//  what the user sees is what ships.

#import <UIKit/UIKit.h>

@class VSContainer;

@interface VSCreateVC : UIViewController

/// Called after a container is successfully created, on the main thread. The
/// panel uses it to offer switching to the new container.
@property (nonatomic, copy) void (^onCreated)(VSContainer *container);

@end
