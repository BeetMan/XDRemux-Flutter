/*
 * Copyright (c) 2021-2024 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */
import matrix4 from '@ohos.matrix4';
import Any from '../../plugin/common/Any';
import Log from '../../util/Log';

/**
 * Dynamic View creation
 * from a recursive data structure
 *
 * exported @Component: DynamicView
 * exported view model classes:
 * - DVModelContainer
 * - DVModel
 * - DVModelParameters
 * - DVModelEvents
 * - DVModelChildren
 *
 * The purpose of exporting the DVModel classes
 * is to make them available to the converter from
 * JD's XML format and the expression parser. These
 * components are expected to generate and update the
 * DVModel.
 *
 * An application written by JS should only import
 * DynamicView, DVModelContainer to be used in their own ArkUI
 * container view.
 */

/**
 * View Model classes
 */

/**
 * Parameters for DynamicView model components.
 * This class is observed to enable reactive updates when parameters change.
 * It serves as a container for component attributes and properties.
 */
@Observed
export class DVModelParameters extends Object {
  /* empty, just get any instance wrapped inside an ObservedObject
  with the help of the decoration */
}

/**
 * Events for DynamicView model components.
 * This class is observed to enable reactive updates when events change.
 * It serves as a container for component event handlers.
 */
@Observed
export class DVModelEvents extends Object {
  /* empty, just get any instance wrapped inside an ObservedObject
  with the help of the decoration */
}

/**
 * Children array for DynamicView model components.
 * This class is observed to enable reactive updates when children change.
 * It serves as a container for child DVModel instances.
 */
@Observed
export class DVModelChildren extends Array<DVModel> {
  /* empty, just get any instance wrapped inside an ObservedObject
  with the help of the decoration */
}

let nextId: number = 1;

/**
 * Model class representing a dynamic view component.
 * This class holds all information needed to render a component dynamically,
 * including its type, parameters, events, children, and optional builder.
 */
@Observed
export class DVModel {
  /** The unique identifier for this model. */
  id_: number;
  /** The component type (e.g., "Column", "Row", "Text", "Image"). */
  compType: string;
  /** The component parameters. */
  params: DVModelParameters;
  /** The component events. */
  events: DVModelEvents;
  /** The child components. */
  children: DVModelChildren;
  /** Optional custom builder function. */
  builder: Any;

  /**
   * Constructs a new DVModel instance.
   * @param compType - The component type (e.g., "Column", "Row", "Text", "Image")
   * @param params - The component parameters
   * @param events - The component events
   * @param children - The child components
   * @param builder - Optional custom builder function
   */
  constructor(compType: string, params: DVModelParameters, events: DVModelEvents, children: DVModelChildren,
    builder?: Any) {
    this.id_ = nextId++;
    this.compType = compType;
    this.params = params ?? new DVModelParameters;
    this.events = events;
    this.children = children;
    this.builder = builder;
  }

  /**
   * Gets the layout parameters for this model.
   * @returns The DVModelParameters instance
   */
  public getLayoutParams(): DVModelParameters {
    return this.params;
  }
}

/**
 * Container for the root DVModel object.
 * This class wraps the root model to provide a container structure.
 */
export class DVModelContainer {
  /** The root DVModel instance. */
  model: DVModel;

  /**
   * Constructs a new DVModelContainer instance.
   * @param model - The root DVModel to contain
   */
  constructor(model: DVModel) {
    this.model = model;
  }
}

/**
 DynamicView is the @Component that does all the work:

 The following 4 features are the key solution elements for dynamic View
 construction and update:

 1. The if statement decides which framework component to create.
 We can not use a factory function here, because that would requite calling
 a regular function inside build() or a @Builder function.

 2. Take note of the @Builder for Row, Column containers:
 These functions create DynamicView Views inside a DynamicView
 view. This behaviour is why we talk about DynamicView as a 'recursive' View.
 All @Builder functions are member functions of the DynamicView @Component to
 retain access ('this.xyz') to its decorated state variables.

 3. The @Extend functions execute attribute and event handler registration functions
 for all attributes and events permissable on the framework component, irrespective
 if DVModelParameters or DVModelEvents objects includes a value or not. If not
 the attribute or event is set to 'undefined' by intention. This is required to unset
 any previously set value.

 4. The scope ('this') of any lambda registered as an event hander function, e.g. for onClick,
 is the @Component, in which the DVModel object is initialized. This said, it is advised to initialize
 the DVModel object in the @Component that is parent to outmost DynamicView. Thereby,
 any event handler function is able to mutate decorated state variables of that @Component

 */

@Component
export struct DynamicView {
  @ObjectLink model: DVModel;
  @ObjectLink children: DVModelChildren;
  @ObjectLink params: DVModelParameters;
  @ObjectLink events: DVModelEvents;
  @BuilderParam customBuilder?: ($$: BuilderParams) => void;

  /**
   * Gets a parameter value from the parameters object.
   * @param params - The parameters object
   * @param element - The parameter key
   * @returns The parameter value, or undefined if not found
   */
  getParams: (params: DVModelParameters, element: string) => string | Any =
    (params: DVModelParameters, element: string): string | Any => {
      let params2 = params as Record<string, Any>;
      return params2[element];
    }

  /**
   * Gets an event handler from the events object.
   * @param events - The events object
   * @param element - The event key
   * @returns The event handler, or undefined if not found
   */
  getEvents: (events: DVModelEvents, element: string) => Any = (events: DVModelEvents, element: string): Any => {
    let events2 = events as Record<string, Any>;
    return events2[element];
  }

  @Styles
  common_attrs() {
    .width(this.getParams(this.params, "width"))
    .height(this.getParams(this.params, "height"))
    .backgroundColor(this.getParams(this.params, "backgroundColor"))
    .onClick(this.getEvents(this.events, "onClick"))
    .margin({
      left: this.getParams(this.params, "marginLeft"),
      right: this.getParams(this.params, "marginRight"),
      top: this.getParams(this.params, "marginTop"),
      bottom: this.getParams(this.params, "marginBottom")
    })
    .onTouch(this.getEvents(this.events, "onTouch"))
    .onFocus(this.getEvents(this.events, "onFocus"))
    .onBlur(this.getEvents(this.events, "onBlur"))
    .translate({
      x: this.getParams(this.params, "translateX"),
      y: this.getParams(this.params, "translateY"),
      z: this.getParams(this.params, "translateZ")
    })
    .transform(this.getParams(this.params, "matrix"))
    .direction(this.getParams(this.params, "direction"))
  }

  @Styles
  clip_attrs() {
    .clip(this.getParams(this.params, "rectWidth") ? new Rect({
      width: this.getParams(this.params, "rectWidth"),
      height: this.getParams(this.params, "rectHeight"),
      radius: this.getParams(this.params, "rectRadius")
    }) : null)
    .clip(this.getParams(this.params, "pathWidth") ? new Path({
      width: this.getParams(this.params, "pathWidth"),
      height: this.getParams(this.params, "pathHeight"),
      commands: this.getParams(this.params, "pathCommands")
    }) : null)
  }

  @Builder
  buildChildren() {
    ForEach(this.children,
      (child: Any) => {
        DynamicView({
          model: child as DVModel,
          params: child.params,
          events: child.events,
          children: child.children,
          customBuilder: child.builder
        })
      },
      (child: Any) => `${child.id_}`
    )
  }

  @Builder
  buildRow() {
    Row() {
      this.buildChildren()
    }
    .common_attrs()
    .clip_attrs()
  }

  @Builder
  buildColumn() {
    Column() {
      this.buildChildren()
    }
    .common_attrs()
    .clip_attrs()
  }

  @Builder
  buildStack() {
    Stack() {
      this.buildChildren()
    }
    .common_attrs()
    .clip_attrs()
    .alignContent(this.getParams(this.params, "alignContent"))
  }

  @Builder
  buildText() {
    Text(`${this.getParams(this.params, "value")}`)
      .common_attrs()
      .fontColor(this.getParams(this.params, "fontColor"))
  }

  @Builder
  buildImage() {
    Image(this.getParams(this.params, "src"))
      .common_attrs()
  }

  @Builder
  buildButton() {
    Button(this.getParams(this.params, "value"))
      .common_attrs()
  }

  @Builder
  buildNodeContainer() {
    NodeContainer(this.getParams(this.params, "nodeController"))
      .common_attrs()
      .position({
        x: (this.params as Record<string, Any>)['left'] as number,
        y: (this.params as Record<string, Any>)['top'] as number
      })
  }

  @Builder
  buildCustom() {
    if (this.customBuilder) {
      this.customBuilder(new BuilderParams(this.params));
    }
  }

  build() {
    if (this.model.compType == "Column") {
      this.buildColumn()
    } else if (this.model.compType == "Row") {
      this.buildRow()
    } else if (this.model.compType == "Stack") {
      this.buildStack()
    } else if (this.model.compType == "Text") {
      this.buildText()
    } else if (this.model.compType == "Image") {
      this.buildImage()
    } else if (this.model.compType == "Button") {
      this.buildButton()
    } else if (this.model.compType == "NodeContainer") {
      this.buildNodeContainer()
    } else {
      this.buildCustom()
    }
  }
}

/**
 * Parameters passed to custom builder functions.
 * This class wraps DVModelParameters for use in custom builders.
 */
export class BuilderParams {
  /** The DVModelParameters to wrap. */
  params: DVModelParameters;

  /**
   * Constructs a new BuilderParams instance.
   * @param params - The DVModelParameters to wrap
   */
  constructor(params: DVModelParameters) {
    this.params = params;
  }
}
